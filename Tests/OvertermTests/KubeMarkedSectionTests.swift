import Foundation
import XCTest

@testable import Overterm
@testable import OvertermCore
@testable import OvertermDatabase
@testable import OvertermDocker
@testable import OvertermKubernetes
@testable import OvertermTerraform
@testable import OvertermShell
@testable import OvertermOvergit
@testable import OvertermAPI

/// What the GitOps section says of the Argo CD apps read from their marks
/// (docs/design/kubernetes/gitops.md, 14.2, 14.3; `KubeMarkedSection`):
/// pure, every row of 14.2.1's table — the mode's own sentence (only
/// `.notServed` says "another cluster", `.noApplications` "aren't in this
/// cluster"), `.undiscovered`'s and `.forbidden`'s, no count while reading,
/// "At least N apps" from a read that wasn't whole, the empty sentences
/// ("carries no marks" only from a whole read), beside Applications read
/// across the cluster or only in some namespaces, R1's first list not yet
/// come, Flux beside the marks; "from rows only" on the Ready chip; an app
/// of a Service alone Unknown, never Ready; Degraded and Unknown ranked
/// with Failed; a Rollout's Deployment "scaled by its Rollout", never a
/// problem; the filters, the groupings, `k`'s argocd line without
/// `--core`; no derived row a kind. Fictional names in the surveyed
/// spoke's shape (`<env>-<ns>-<name>-service`).
final class KubeMarkedSectionTests: XCTestCase {
    typealias Status = KubeMarkedHealth.Status
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    // MARK: Fixtures

    private func marks(_ instance: String, _ groupKind: String, _ namespace: String, _ name: String, installation: String? = nil) -> KubeMarkWire {
        var marks = KubeMarkWire()
        marks.tracking = .own(KubeTrackingID.parse("\(instance):\(groupKind):\(namespace)/\(name)")!)
        marks.installation = installation
        return marks
    }

    private static let groupKinds: [KubeMarkedKind: String] = [
        .deployment: "apps/Deployment", .statefulSet: "apps/StatefulSet", .rollout: "argoproj.io/Rollout", .service: "/Service",
        .ingress: "networking.k8s.io/Ingress", .persistentVolumeClaim: "/PersistentVolumeClaim", .horizontalPodAutoscaler: "autoscaling/HorizontalPodAutoscaler",
        .job: "batch/Job", .cronJob: "batch/CronJob",
    ]

    private func member(
        _ kind: KubeMarkedKind, _ name: String, app: String, namespace: String = "team-1", _ status: Status?, _ sentence: String, fromRow: Bool = false,
        unread: Bool = false, scaledToZero: Bool = false, images: [String] = [], installation: String? = nil, workloadRef: String? = nil,
        hook: String? = nil
    ) -> KubeMarkedMember {
        var wire = marks(app, Self.groupKinds[kind] ?? "apps/Deployment", namespace, name, installation: installation)
        wire.hook = hook
        let verdict = KubeMarkedHealth.Verdict(status: status, sentence: sentence, fromRow: fromRow, unread: unread, scaledToZero: scaledToZero)
        return KubeMarkedMember(
            id: .init(kind: kind, namespace: namespace, name: name), marks: wire, health: verdict, images: images, created: now.addingTimeInterval(-3600),
            workloadRef: workloadRef)
    }

    private func ranked(_ members: [KubeMarkedMember], instance: String, installation: String = "") -> KubeMarkedRanked {
        let app = KubeMarkedApp.make(key: .init(installation: installation, instance: instance), members)!
        return KubeMarkedRanked(app: app, health: app.health)
    }

    /// An app of one Deployment, its state as said.
    private func deployment(_ instance: String, _ name: String, namespace: String = "team-1", _ status: Status, _ sentence: String, fromRow: Bool = false, installation: String? = nil)
        -> KubeMarkedRanked
    {
        ranked(
            [member(.deployment, name, app: instance, namespace: namespace, status, sentence, fromRow: fromRow, images: ["registry.acme.example/acme/\(name):4.12.0"], installation: installation)],
            instance: instance, installation: installation ?? "")
    }

    private func whole(_ kinds: [String] = ["Deployments", "StatefulSets", "DaemonSets"]) -> KubeMarkedReading {
        var reading = KubeMarkedReading()
        reading.kinds = kinds
        reading.listed = Set(kinds)
        return reading
    }

    private func spoke() -> [KubeMarkedRanked] {
        let apps = [
            deployment("prod-team-1-acme-pay-service", "acme-pay", .progressing, "1 old replica pending termination"),
            deployment("prod-team-2-acme-cart-service", "acme-cart", namespace: "team-2", .degraded, "rollout stalled (ProgressDeadlineExceeded)"),
            deployment("prod-team-3-acme-api-service", "acme-api", namespace: "team-3", .healthy, "2/2 ready", fromRow: true),
            deployment("prod-team-4-acme-web", "acme-web", namespace: "team-4", .healthy, "2/2 available"),
        ]
        var book = apps
        book.sort(by: KubeMarkedBook.ordered)
        return book
    }

    // MARK: 14.2.1's table: the mode's sentence and the count

    func testOnlyNotServedSaysAnotherClusterAndEachModeItsOwn() {
        let apps = spoke()
        let reading = whole()
        func lead(_ reason: KubeMarkedAppsMode.Reason) -> String? {
            KubeMarkedSection.lines(mode: .only(reason), context: "fake-prod", apps: apps.map(\.app), reading: reading, tally: .init(), kinds: [], unread: 0).lead
        }
        XCTAssertEqual(
            lead(.notServed),
            "Argo CD runs in another cluster — not in your kubeconfig. These 4 apps are read from the marks Argo CD leaves on their objects.")
        XCTAssertEqual(lead(.noApplications), "Argo CD's Applications for these aren't in this cluster. These 4 apps are read from the marks Argo CD leaves on their objects.")
        XCTAssertEqual(
            lead(.undiscovered),
            "Couldn't tell whether Argo CD runs in fake-prod: argoproj.io didn't answer discovery. These 4 apps are read from the marks on their objects.")
        XCTAssertEqual(lead(.forbidden), "Argo CD's Applications can't be read in fake-prod (forbidden). These 4 apps are read from the marks on their objects.")
        for reason in [KubeMarkedAppsMode.Reason.noApplications, .undiscovered, .forbidden] {
            XCTAssertFalse(lead(reason)?.contains("another cluster") ?? true, "only .notServed says another cluster: \(reason)")
            XCTAssertFalse(lead(reason)?.contains("isn't installed") ?? true)
        }
        let lines = KubeMarkedSection.lines(
            mode: .only(.notServed), context: "fake-prod", apps: apps.map(\.app), reading: reading, tally: .init(), kinds: ["Deployments", "Services"], unread: 0)
        XCTAssertEqual(
            lines.limits,
            "No sync status, repository or revision: those are in the Application, in Argo CD's cluster. Health is Argo CD's built-in rules applied to what is here.")
        XCTAssertTrue(lines.hover.contains("An app deleted in Argo CD without deleting its resources leaves the same marks."), lines.hover)
        XCTAssertTrue(lines.hover.contains("Custom health checks configured in Argo CD aren't known here."))
        XCTAssertTrue(lines.hover.contains("Read here: Deployments and Services."), lines.hover)
        XCTAssertTrue(lines.hover.contains("ConfigMaps and Secrets are never listed"))
        XCTAssertNil(lines.installations, "one installation: not said")
        XCTAssertEqual(
            KubeMarkedSection.lines(mode: .only(.forbidden), context: "fake-prod", apps: apps.map(\.app), reading: reading, tally: .init(), kinds: [], unread: 0).limits,
            "No sync status, repository or revision: those are in the Application, which can't be read here. Health is Argo CD's built-in rules applied to what is here.")
        XCTAssertEqual(
            KubeMarkedSection.lines(mode: .only(.notServed), context: "fake-prod", apps: [], reading: reading, tally: .init(), kinds: [], unread: 0),
            KubeMarkedSection.Lines(), "no app read: the empty sentence says it, no header line")
        XCTAssertEqual(KubeMarkedSection.lines(mode: .off, context: "fake-prod", apps: apps.map(\.app), reading: reading, tally: .init(), kinds: [], unread: 0), KubeMarkedSection.Lines())
    }

    /// No Argo CD mark anywhere, only `app.kubernetes.io/instance` (D-5):
    /// "probably", never that Argo CD runs in another cluster.
    func testAppsByTheInstanceLabelAloneAreOnlyProbablyArgoCDs() {
        var marks = KubeMarkWire()
        marks.appInstance = "acme-shop"
        let member = KubeMarkedMember(
            id: .init(kind: .deployment, namespace: "team-1", name: "acme-shop"), marks: marks,
            health: KubeMarkedHealth.Verdict(status: .healthy, sentence: "2/2 available"))
        let app = KubeMarkedApp.make(key: .init(installation: "", instance: "acme-shop"), [member])!
        XCTAssertEqual(app.mark, .appInstance)
        let lead = KubeMarkedSection.lines(mode: .only(.notServed), context: "fake-prod", apps: [app], reading: whole(), tally: .init(), kinds: [], unread: 0).lead
        XCTAssertEqual(
            lead, "No Argo CD tracking id is here: this app is only probably Argo CD's, grouped by app.kubernetes.io/instance — a label Helm and kustomize set too.")
        XCTAssertFalse(lead?.contains("another cluster") ?? true)
        let row = KubeMarkedSection.row(KubeMarkedRanked(app: app, health: app.health), installations: false)
        XCTAssertTrue(row.tags.contains(.text("probably: app.kubernetes.io/instance")))
    }

    func testWhileReadingThereIsNoCount() {
        var reading = KubeMarkedReading()
        reading.kinds = ["Deployments", "StatefulSets", "DaemonSets"]
        reading.listed = ["Deployments"]
        XCTAssertTrue(reading.isReading)
        let lead = KubeMarkedSection.lines(mode: .only(.notServed), context: "fake-prod", apps: spoke().map(\.app), reading: reading, tally: .init(), kinds: [], unread: 0).lead
        XCTAssertEqual(lead, "Argo CD runs in another cluster — not in your kubeconfig. Reading the marks on Deployments, StatefulSets and DaemonSets…")
        XCTAssertEqual(KubeMarkedSection.header(apps: 4, reading: reading, readAt: nil, now: now), "Argo CD: from marks · reading marks…", "no count while reading")
        XCTAssertEqual(KubeMarkedSection.empty(.notServed, context: "fake-prod", scope: .all, reading: reading), "Reading the marks on Deployments, StatefulSets and DaemonSets…")
    }

    func testAPartialReadSaysAtLeastNApps() {
        var reading = whole()
        reading.refused["Deployments"] = ["team-a", "team-b", "team-c"]
        let lead = KubeMarkedSection.lines(mode: .only(.notServed), context: "fake-prod", apps: spoke().map(\.app), reading: reading, tally: .init(), kinds: [], unread: 0).lead
        XCTAssertEqual(
            lead,
            "Argo CD runs in another cluster — not in your kubeconfig. At least 4 apps, from what could be read: Deployments refused in 3 namespaces (team-a, team-b, team-c).")
        XCTAssertEqual(KubeMarkedSection.header(apps: 4, reading: reading, readAt: now.addingTimeInterval(-40), now: now), "Argo CD: from marks · at least 4 apps · read just now")
        var fallback = whole()
        fallback.fallback["Deployments"] = ["team-1", "team-2"]
        XCTAssertEqual(
            KubeMarkedSection.countSentence(.notServed, apps: 2, reading: fallback),
            "At least 2 apps, from what could be read: Deployments refused across the cluster; read in team-1, team-2 every 5 min.")
        XCTAssertEqual(KubeMarkedSection.header(apps: 894, reading: whole(), readAt: now.addingTimeInterval(-180), now: now), "Argo CD: from marks · 894 apps · read 3m ago")
    }

    func testACutOrRefusedReadNeverSaysNoMarks() {
        var cut = whole()
        cut.rowCuts["Deployments"] = "Deployments: the list stopped at 5,000; the rest not read"
        XCTAssertEqual(
            KubeMarkedSection.empty(.notServed, context: "fake-prod", scope: .all, reading: cut),
            "No Argo CD marks found in what could be read: Deployments: the list stopped at 5,000; the rest not read")
        var refused = whole()
        refused.refused["Deployments"] = [KubeMarkedReading.acrossTheCluster]
        XCTAssertEqual(
            KubeMarkedSection.empty(.notServed, context: "fake-prod", scope: .all, reading: refused), "No Argo CD marks found in what could be read: Deployments refused across the cluster")
        var fallback = whole()
        fallback.fallback["Deployments"] = ["team-1"]
        XCTAssertFalse(KubeMarkedSection.empty(.notServed, context: "fake-prod", scope: .all, reading: fallback).contains("carries"))
        for reason in [KubeMarkedAppsMode.Reason.notServed, .noApplications, .undiscovered, .forbidden] {
            for reading in [cut, refused, fallback] {
                XCTAssertFalse(KubeMarkedSection.empty(reason, context: "fake-prod", scope: .all, reading: reading).contains("carries"), "\(reason)")
            }
        }
        // A whole read: none carries, in the mode's words.
        XCTAssertEqual(
            KubeMarkedSection.empty(.notServed, context: "fake-prod", scope: .namespace("team-1"), reading: whole()),
            "No Argo CD Application is served by fake-prod, and no Deployment, StatefulSet or DaemonSet in namespace team-1 carries Argo CD's marks.")
        XCTAssertEqual(
            KubeMarkedSection.empty(.undiscovered, context: "fake-prod", scope: .all, reading: whole()),
            "Couldn't tell whether Argo CD runs in fake-prod: argoproj.io didn't answer discovery. No Deployment, StatefulSet or DaemonSet in all namespaces carries Argo CD's marks.")
        XCTAssertEqual(
            KubeMarkedSection.empty(.forbidden, context: "fake-prod", scope: .all, reading: whole()),
            "Argo CD's Applications can't be read in fake-prod (forbidden). No Deployment, StatefulSet or DaemonSet in all namespaces carries Argo CD's marks.")
        XCTAssertFalse(KubeMarkedSection.empty(.undiscovered, context: "fake-prod", scope: .all, reading: whole()).contains("is served by"), "can't tell: never said not served")
    }

    // MARK: Rows

    func testARowsColumns() throws {
        let app = ranked(
            [
                member(.deployment, "acme-pay", app: "prod-team-1-acme-pay-service", .degraded, "rollout stalled (ProgressDeadlineExceeded)", images: ["registry.acme.example/acme/acme-pay:4.12.0"]),
                member(.deployment, "acme-pay-worker", app: "prod-team-1-acme-pay-service", .healthy, "2/2 available", images: ["registry.acme.example/acme/acme-pay-worker:4.12.0"]),
                member(.service, "acme-pay", app: "prod-team-1-acme-pay-service", .healthy, "service"),
            ], instance: "prod-team-1-acme-pay-service")
        let row = KubeMarkedSection.row(app, installations: false)
        XCTAssertEqual(row.role, .markedApp)
        XCTAssertEqual(row.role.short, "Marks")
        XCTAssertEqual(row.tool, .argo)
        XCTAssertEqual(row.ref.description, "prod-team-1-acme-pay-service", "a plain name shown bare")
        XCTAssertEqual(row.state, .failed)
        XCTAssertEqual(row.marked?.word, "Failed")
        XCTAssertEqual(row.why, "rollout stalled (ProgressDeadlineExceeded) · Deployment acme-pay")
        XCTAssertEqual(row.into, "team-1")
        XCTAssertEqual(row.revision, "", "Argo CD's revision is the Application's")
        XCTAssertEqual(row.source, "…/acme-pay:4.12.0 +1", "the main image, its registry left out, then how many more")
        XCTAssertEqual(row.tags, [.text("2 Deploy · 1 Svc")])
        XCTAssertTrue(row.hover.contains("Argo CD's rule: Degraded"), row.hover)
        XCTAssertTrue(row.hover.contains("prod-team-1-acme-pay-service: in Argo CD's own namespace"), row.hover)
        XCTAssertTrue(row.hover.contains("repo: matches nothing here"), row.hover)
        XCTAssertEqual(row.resource, "", "no kind of its own")
        XCTAssertNil(KubeGitOpsSection.role(row.resource))
        XCTAssertTrue(row.id.hasPrefix(KubeMarkedSection.idPrefix))
        // An `<appNamespace>_<name>` app: its namespace and name.
        let namespaced = KubeMarkedSection.row(deployment("apps_prod-team-2-acme-cart", "acme-cart", namespace: "team-2", .healthy, "2/2 available"), installations: false)
        XCTAssertEqual(namespaced.ref.description, "apps/prod-team-2-acme-cart")
        // Several installations: each row says which.
        let other = KubeMarkedSection.row(deployment("prod-team-5-acme-ads-service", "acme-ads", .healthy, "2/2 available", installation: "hub-b"), installations: true)
        XCTAssertTrue(other.tags.contains(.text("installation hub-b")), "\(other.tags)")
        XCTAssertEqual(other.marked?.installation, "hub-b")
        let plain = KubeMarkedSection.row(deployment("prod-team-5-acme-web", "acme-web", .healthy, "2/2 available"), installations: true)
        XCTAssertEqual(plain.tags, [.text("1 Deploy")], "none: the header counts those, never a tag on each")
        XCTAssertEqual(KubeGitOpsTag.text("2 Deploy").said(now: now), "2 Deploy")
    }

    func testFromRowsOnlyIsCountedOnTheReadyChip() {
        // The surveyed shape: nearly every app has an HPA, Healthy from its
        // row for good — it never keeps a settled app on the chip's count.
        let instance = "prod-team-7-acme-feed-service"
        let withHPA = ranked(
            [
                member(.deployment, "acme-feed", app: instance, namespace: "team-7", .healthy, "2/2 available"),
                member(.horizontalPodAutoscaler, "acme-feed", app: instance, namespace: "team-7", .healthy, "every target read", fromRow: true),
            ], instance: instance)
        let rows = KubeMarkedSection.derived(spoke() + [withHPA], mode: .only(.notServed), applications: .notYetListed).shown
        let ready = rows.filter { $0.state == .ready }
        XCTAssertEqual(ready.count, 3)
        let fromRows = ready.count { $0.marked?.fromRows == true }
        XCTAssertEqual(fromRows, 1, "acme-api is ready by its row alone; acme-feed's Deployment is settled, its HPA's row is its word")
        XCTAssertEqual(KubeGitOpsSection.chipText(.ready, ready.count, fromRows: fromRows), "3 ready (1 from rows only)")
        XCTAssertEqual(KubeGitOpsSection.chipText(.ready, 878, fromRows: 0), "878 ready")
        let api = rows.first { $0.ref.name == "prod-team-3-acme-api-service" }
        XCTAssertTrue(api?.hover.contains("Deployment acme-api is from its row") == true, api?.hover ?? "")
        let feed = rows.first { $0.ref.name == instance }
        XCTAssertFalse(feed?.hover.contains("cells alone can hide") ?? true, feed?.hover ?? "")
    }

    // MARK: Served with none listed, Flux beside, the notes

    /// The development cluster's case before and without any mark found
    /// (14.12, consequence 1): while the marks are read, what is read;
    /// refused, what couldn't be — in the header plainly and in the notes
    /// when no sentence above says it; read whole with none, the empty
    /// sentence and the tools' header — never today's "no GitOps object".
    func testServedWithNoneListedTheMarksAreSaidBeforeAndWithoutAnyApp() {
        var reading = KubeMarkedReading()
        reading.kinds = ["Deployments", "StatefulSets", "DaemonSets"]
        func header(_ reading: KubeMarkedReading, apps: Int = 0, flux: Int = 0) -> String {
            KubeMarkedSection.sectionHeader(
                mode: .only(.noApplications), argo: 2, flux: flux, summarisedAt: now.addingTimeInterval(-10), summarising: false, apps: apps, reading: reading,
                readAt: now.addingTimeInterval(-10), now: now)
        }
        XCTAssertEqual(header(reading), "Argo CD: from marks · reading marks…")
        XCTAssertEqual(KubeMarkedSection.empty(.noApplications, context: "fake-dev", scope: .all, reading: reading), "Reading the marks on Deployments, StatefulSets and DaemonSets…")
        // Read whole, none: the tools served again, and the sentence.
        let none = whole()
        XCTAssertEqual(header(none), "Argo CD 2 kinds · summarised just now")
        XCTAssertEqual(
            KubeMarkedSection.empty(.noApplications, context: "fake-dev", scope: .all, reading: none),
            "No Argo CD Application deploys here, and no Deployment, StatefulSet or DaemonSet in all namespaces carries Argo CD's marks.")
        // Refused, none found: said plainly, never "at least 0 apps".
        var refused = whole()
        refused.refused["Deployments"] = [KubeMarkedReading.acrossTheCluster]
        XCTAssertEqual(header(refused), "Argo CD: from marks · none found in what could be read · read just now")
        XCTAssertFalse(header(refused).contains("0 apps"))
        let lines = KubeMarkedSection.lines(mode: .only(.noApplications), context: "fake-dev", apps: [], reading: refused, tally: .init(), kinds: [], unread: 0)
        XCTAssertNil(lines.lead)
        // The refusal said once: by the empty sentence when it is drawn, else by the notes.
        XCTAssertEqual(KubeMarkedSection.notes(refused, mode: .only(.noApplications), lines: lines, emptyDrawn: true), [])
        XCTAssertEqual(KubeMarkedSection.notes(refused, mode: .only(.noApplications), lines: lines, emptyDrawn: false), ["Deployments refused across the cluster"])
        XCTAssertEqual(KubeMarkedSection.notes(refused, mode: .off, lines: lines, emptyDrawn: false), [])
    }

    /// Flux served, Argo CD not, no Argo CD mark: Flux's header as before
    /// the marks (never "Argo CD: from marks · 0 apps"); a refused marks
    /// read said in the header and the notes, Flux's rows taking the
    /// place of the empty sentence.
    func testFluxWithNoArgoMarksKeepsItsHeaderAndARefusalIsSaid() {
        func header(_ reading: KubeMarkedReading, apps: Int = 0, flux: Int = 6) -> String {
            KubeMarkedSection.sectionHeader(
                mode: .only(.notServed), argo: 0, flux: flux, summarisedAt: now.addingTimeInterval(-180), summarising: false, apps: apps, reading: reading,
                readAt: now.addingTimeInterval(-30), now: now)
        }
        XCTAssertEqual(header(whole()), "Flux 6 kinds · summarised 3m ago")
        XCTAssertEqual(header(whole(), flux: 0), "", "a pure spoke read whole with no mark: the empty sentence says it, nothing summarised")
        XCTAssertEqual(header(whole(), apps: 4), "Argo CD: from marks · 4 apps · read just now · Flux 6 kinds · summarised 3m ago")
        var refused = whole()
        refused.refused["Deployments"] = ["team-a", "team-b"]
        XCTAssertEqual(header(refused), "Argo CD: from marks · none found in what could be read · read just now · Flux 6 kinds · summarised 3m ago")
        let lines = KubeMarkedSection.lines(mode: .only(.notServed), context: "fake-prod", apps: [], reading: refused, tally: .init(), kinds: [], unread: 0)
        XCTAssertEqual(
            KubeMarkedSection.notes(refused, mode: .only(.notServed), lines: lines, emptyDrawn: false), ["Deployments refused in 2 namespaces (team-a, team-b)"],
            "Flux's rows drawn, no empty sentence: the notes say it")
        // With apps, the lead's "At least" names it: once.
        let withApps = KubeMarkedSection.lines(mode: .only(.notServed), context: "fake-prod", apps: spoke().map(\.app), reading: refused, tally: .init(), kinds: [], unread: 0)
        XCTAssertTrue(withApps.saysUnread)
        XCTAssertTrue(withApps.lead?.contains("Deployments refused in 2 namespaces") == true)
        XCTAssertEqual(KubeMarkedSection.notes(refused, mode: .only(.notServed), lines: withApps, emptyDrawn: false), [])
        // While reading, the lead names nothing refused yet: the notes do.
        var reading = refused
        reading.listed = ["StatefulSets"]
        let readingLines = KubeMarkedSection.lines(mode: .only(.notServed), context: "fake-prod", apps: spoke().map(\.app), reading: reading, tally: .init(), kinds: [], unread: 0)
        XCTAssertFalse(readingLines.saysUnread)
        XCTAssertEqual(KubeMarkedSection.notes(reading, mode: .only(.notServed), lines: readingLines, emptyDrawn: false), ["Deployments refused in 2 namespaces (team-a, team-b)"])
    }

    // MARK: Apps only probably Argo CD's

    /// Grouped by `app.kubernetes.io/instance` alone — ingress-nginx or
    /// cert-manager applied from static manifests on a kind cluster: every
    /// sentence says only "probably", never that Argo CD runs in another
    /// cluster or that an Application is missing (14.3, D-5).
    func testAppsOnlyProbablyArgoCDsSayNothingOfWhereArgoCDRuns() throws {
        var marks = KubeMarkWire()
        marks.appInstance = "acme-ingress"
        let deployment = KubeMarkedMember(
            id: .init(kind: .deployment, namespace: "acme-ingress", name: "acme-ingress-controller"), marks: marks,
            health: .init(status: .healthy, sentence: "1/1 available"), images: ["registry.acme.example/acme/ingress:1.11.2"])
        let app = try XCTUnwrap(KubeMarkedApp.make(key: .init(installation: "", instance: "acme-ingress"), [deployment]))
        let ranked = KubeMarkedRanked(app: app, health: app.health)
        let definite = ["another cluster", "Argo CD's cluster", "kubeconfig", "isn't in this cluster", "Argo CD's own namespace", "Argo CD runs"]
        for mode in [KubeMarkedAppsMode.only(.notServed), .only(.noApplications), .only(.forbidden), .only(.undiscovered)] {
            let detail = KubeMarkedAppDetail.make(ranked, mode: mode, context: "kind-fake")
            XCTAssertEqual(detail.label, "Probably an Argo CD app")
            XCTAssertEqual(
                detail.lead,
                "No Argo CD tracking id is here: this app is only probably Argo CD's, grouped by app.kubernetes.io/instance — a label Helm and kustomize set too.")
            let words = [detail.absent, detail.lead ?? "", detail.manifests, detail.knowsTitle, KubeMarkedAppDetail.undone(mode, probable: true)]
            for text in words + detail.facts + detail.knows.map(\.place) {
                for claim in definite { XCTAssertFalse(text.contains(claim), "\(mode): \(text)") }
            }
            XCTAssertTrue(detail.absent.contains("only probably Argo CD's"), detail.absent)
            let lines = KubeMarkedSection.lines(mode: mode, context: "kind-fake", apps: [app], reading: whole(), tally: .init(), kinds: ["Deployments"], unread: 0)
            for text in [lines.lead ?? "", lines.limits ?? ""] {
                for claim in definite { XCTAssertFalse(text.contains(claim), "\(mode): \(text)") }
            }
            for claim in ["Argo CD runs", "Argo CD's cluster", "kubeconfig"] { XCTAssertFalse(lines.hover.contains(claim), "\(mode): \(lines.hover)") }
            XCTAssertTrue(lines.hover.contains("may be none of Argo CD's"), lines.hover)
            XCTAssertFalse(KubeMarkedSection.revisionHover(mode, probable: true).contains("another cluster"))
        }
        let row = KubeMarkedSection.row(ranked, installations: false)
        XCTAssertEqual(row.marked?.probable, true)
        XCTAssertTrue(row.hover.hasSuffix("if Argo CD deploys it, those are in its Application (repo: matches nothing here)."), row.hover)
        for claim in definite { XCTAssertFalse(row.hover.contains(claim), row.hover) }
        XCTAssertEqual(
            KubeMarkedSection.header(apps: 1, reading: whole(), readAt: now, now: now, probable: true), "Argo CD, probably: by app.kubernetes.io/instance · 1 app · read just now")
        // Beside Applications: never listed, never "not in this cluster".
        let coexistence = KubeMarkedAppsMode.Coexistence(missing: [app.key])
        let beside = KubeMarkedSection.derived([ranked], mode: .beside(coexistence), applications: .acrossCluster([KubeRowID(namespace: "argocd", name: "acme-shop")]))
        XCTAssertEqual(beside, KubeMarkedSection.Derived(), "an operator's or a chart's workload is no missing Application")
        // The definite words stay for Argo CD's own marks.
        let tracked = spoke()[0]
        XCTAssertEqual(KubeMarkedAppDetail.make(tracked, mode: .only(.notServed), context: "fake-prod").label, "Argo CD app")
        XCTAssertTrue(KubeMarkedSection.revisionHover(.only(.notServed)).contains("another cluster"))
    }

    // MARK: Beside Applications, the muted line

    func testBesideApplicationsTheMutedLineIsAlwaysShownWithTheirRows() {
        let apps = spoke()
        let coexistence = KubeMarkedAppsMode.Coexistence(missing: [apps[0].app.key])
        let lines = KubeMarkedSection.lines(mode: .beside(coexistence), context: "fake-prod", apps: apps.map(\.app), reading: whole(), tally: .init(), kinds: [], unread: 0)
        XCTAssertEqual(
            lines.limits,
            "No sync status, repository or revision: those are in the Application, in Argo CD's cluster. Health is Argo CD's built-in rules applied to what is here.",
            "shown whether or not their chip is pressed")
        XCTAssertFalse(lines.hover.isEmpty)
        let unreadOnly = KubeMarkedAppsMode.Coexistence(unknown: [apps[1].app.key])
        let counted = KubeMarkedSection.lines(mode: .beside(unreadOnly), context: "fake-prod", apps: apps.map(\.app), reading: whole(), tally: .init(), kinds: [], unread: 1)
        XCTAssertNil(counted.limits, "none listed: no line about them")
        XCTAssertEqual(counted.unread, "1 marked app whose Application's namespace couldn't be read: not listed")
        XCTAssertEqual(KubeMarkedSection.besideHeader("Argo CD 2 kinds · summarised 2m ago", readAt: nil, now: now, reading: true), "Argo CD 2 kinds · summarised 2m ago · reading marked apps…")
    }

    // MARK: Cluster-supplied images

    /// A row's Images cell is the cluster's text: each image is capped and
    /// stripped of control and format characters (a bidi override) where
    /// its member is made, as a GET's are, and every hover is capped at 4 KB.
    func testImagesAreCappedAndStrippedWhereMembersAreMade() {
        let long = "registry.acme.example/acme/" + String(repeating: "a", count: 40_000) + ":1.0"
        let cell = ["registry.acme.example/acme/web:4.12.0\u{202E}0.1", long, "<none>"].joined(separator: ",") + String(repeating: ",acme/x:1", count: 50)
        let images = KubeMarkedMember.images(inCell: cell)
        XCTAssertEqual(images.first, "registry.acme.example/acme/web:4.12.00.1", "the override dropped")
        XCTAssertTrue(images.allSatisfy { $0.count <= KubeMarkWire.linkCap }, "\(images.map(\.count))")
        XCTAssertLessThanOrEqual(images.count, KubeMarkedWorkloadWire.containersKept)
        XCTAssertFalse(images.contains { $0.unicodeScalars.contains { $0.properties.generalCategory == .format } })
        let many = (0..<8).map { "registry.acme.example/acme/\($0)/" + String(repeating: "b", count: 1000) }
        XCTAssertLessThanOrEqual(KubeMarkedSection.sourceHover(many).utf8.count, KubeGitOpsMessage.hoverLimit)
        let instance = "prod-team-1-acme-wide-service"
        let wide = ranked(
            (0..<9).map { member(.deployment, "acme-wide-\($0)", app: instance, .healthy, "1/1 available", images: [many[$0 % many.count] + "\($0)"]) }, instance: instance)
        let detail = KubeMarkedAppDetail.make(wide, mode: .only(.notServed), context: "fake-prod")
        XCTAssertTrue((detail.facts + detail.images).allSatisfy { $0.utf8.count <= KubeGitOpsMessage.hoverLimit })
    }

    func testAnAppWithOnlyAServiceReadIsUnknownNeverReady() {
        let app = ranked(
            [
                member(.service, "acme-edge", app: "prod-team-6-acme-edge-service", namespace: "team-6", .healthy, "service"),
                member(.ingress, "acme-edge", app: "prod-team-6-acme-edge-service", namespace: "team-6", .healthy, "address assigned"),
            ], instance: "prod-team-6-acme-edge-service")
        let row = KubeMarkedSection.row(app, installations: false)
        XCTAssertEqual(row.state, .unknown)
        XCTAssertEqual(row.marked?.word, "Unknown")
        XCTAssertEqual(row.why, KubeMarkedHealth.noWorkload)
        XCTAssertNotEqual(row.state, .ready)
        let rows = KubeGitOpsSection.Rows(shown: [row])
        XCTAssertEqual(KubeGitOpsSection.visible(rows, chip: nil, hideReady: true, tool: nil, notPlaced: false, text: "").map(\.id), [row.id], "never hidden with the Ready ones")
    }

    func testDegradedAndUnknownRanksWithFailed() {
        let app = ranked(
            [
                member(.deployment, "acme-search", app: "prod-team-5-acme-search-service", namespace: "team-5", .degraded, "rollout stalled (ProgressDeadlineExceeded)"),
                member(.persistentVolumeClaim, "acme-search-data", app: "prod-team-5-acme-search-service", namespace: "team-5", .unknown, "volume claim Released"),
            ], instance: "prod-team-5-acme-search-service")
        XCTAssertEqual(app.health.status, .unknown, "Argo CD's word: Unknown is its worst")
        let row = KubeMarkedSection.row(app, installations: false)
        XCTAssertEqual(row.marked?.word, "Unknown")
        XCTAssertEqual(row.state, .failed, "ranked with its Degraded member (D-7)")
        XCTAssertTrue(row.why.hasPrefix("rollout stalled (ProgressDeadlineExceeded) · Deployment acme-search"), row.why)
        let progressing = KubeMarkedSection.row(deployment("prod-team-1-acme-pay-service", "acme-pay", .progressing, "2/4 updated"), installations: false)
        let ready = KubeMarkedSection.row(deployment("prod-team-4-acme-web", "acme-web", .healthy, "2/2 available"), installations: false)
        let rows = KubeGitOpsSection.rows(summaries: [], live: [:], listed: [], scope: .all, now: now, derived: .init(shown: [ready, progressing, row]))
        XCTAssertEqual(rows.shown.map(\.id), [row.id, progressing.id, ready.id], "problems first: the Unknown with a Degraded member with Failed")
        XCTAssertEqual(KubeGitOpsSection.chips(rows.shown).first?.state, .failed)
        XCTAssertTrue(KubeGitOpsSection.visible(rows, chip: nil, hideReady: true, tool: nil, notPlaced: false, text: "").contains { $0.id == row.id })
    }

    /// Survey consequence 2: a Rollout's phase is its app's health, and the
    /// Deployment it runs, scaled to 0 by the Rollouts controller, reads
    /// "scaled by its Rollout" — never a problem, never "scaled to 0".
    func testARolloutsDeploymentReadsScaledByItsRollout() {
        let instance = "prod-team-0-acme-canary-service"
        let app = ranked(
            [
                member(.rollout, "acme-canary", app: instance, namespace: "team-0", .healthy, "rollout healthy", workloadRef: "acme-canary"),
                member(.deployment, "acme-canary", app: instance, namespace: "team-0", .healthy, "scaled to 0", scaledToZero: true),
            ], instance: instance)
        let row = KubeMarkedSection.row(app, installations: false)
        XCTAssertEqual(row.state, .ready)
        XCTAssertTrue(row.hover.contains("Deployment acme-canary: scaled by its Rollout"), row.hover)
        XCTAssertFalse(row.hover.contains("scaled to 0"), row.hover)
        let detail = KubeMarkedAppDetail.make(app, mode: .only(.notServed), context: "fake-prod")
        let members = detail.tree.map { $0.said(namespaced: detail.namespaced) }
        XCTAssertTrue(members.contains { $0.contains("Deployment acme-canary — Healthy: scaled by its Rollout") }, "\(members)")
        XCTAssertEqual(detail.rollouts, "Its Argo Rollout is read for its health only: promote and abort are Argo Rollouts' — not here.")
        // A Rollout not read yet: Unknown, never Ready from the Deployment it scales.
        let unread = ranked(
            [
                member(.rollout, "acme-canary", app: instance, namespace: "team-0", nil, "its phase isn't read yet", unread: true),
                member(.deployment, "acme-canary", app: instance, namespace: "team-0", .healthy, "scaled to 0", scaledToZero: true),
            ], instance: instance)
        let waiting = KubeMarkedSection.row(unread, installations: false)
        XCTAssertEqual(waiting.state, .unknown)
        XCTAssertNotEqual(waiting.state, .failed)
        // A Degraded Rollout: its app Failed, the Rollout the cause.
        let degraded = ranked(
            [
                member(.rollout, "acme-blue", app: "prod-team-1-acme-blue-service", .degraded, "rollout degraded", workloadRef: "acme-blue"),
                member(.deployment, "acme-blue", app: "prod-team-1-acme-blue-service", .healthy, "scaled to 0", scaledToZero: true),
            ], instance: "prod-team-1-acme-blue-service")
        let blue = KubeMarkedSection.row(degraded, installations: false)
        XCTAssertEqual(blue.state, .failed)
        XCTAssertEqual(blue.why, "rollout degraded · Rollout acme-blue", "the Rollout, never its scaled Deployment")
    }

    func testAHookIsUnderItsAppNeverInItsHealth() {
        let instance = "prod-team-2-acme-orders-service"
        let app = ranked(
            [
                member(.deployment, "acme-orders", app: instance, namespace: "team-2", .healthy, "2/2 available"),
                member(.job, "acme-orders-migrate", app: instance, namespace: "team-2", .degraded, "job failed", hook: "PreSync"),
            ], instance: instance)
        let row = KubeMarkedSection.row(app, installations: false)
        XCTAssertEqual(row.state, .ready, "a failed hook isn't its health")
        XCTAssertTrue(row.hover.contains("Job acme-orders-migrate: a hook, not counted, as in Argo CD"), row.hover)
        let detail = KubeMarkedAppDetail.make(app, mode: .only(.notServed), context: "fake-prod")
        XCTAssertEqual(
            detail.hooks.map { $0.said(namespaced: detail.namespaced) }, ["Job acme-orders-migrate — Degraded: job failed — a hook (PreSync): not counted, as in Argo CD"])
    }

    func testTheHoverIsCappedAtFourKilobytes() {
        let instance = "prod-team-1-acme-big-service"
        let members = (0..<200).map { member(.deployment, String(format: "acme-big-%03d-with-a-long-name", $0), app: instance, .healthy, "2/2 available") }
        let row = KubeMarkedSection.row(ranked(members, instance: instance), installations: false)
        XCTAssertLessThanOrEqual(row.hover.utf8.count, KubeGitOpsMessage.hoverLimit)
        XCTAssertTrue(row.hover.hasSuffix("…"))
        XCTAssertEqual(row.why, "200 objects ready")
    }

    // MARK: Beside Applications read

    func testBesideApplicationsReadAcrossTheClusterOnlyThoseMissingAreListed() {
        let apps = spoke() + [deployment("prod-team-5-acme-ads-service", "acme-ads", .healthy, "2/2 available", installation: "hub-b")]
        // Applications listed across the cluster: acme-pay's is there; one named as acme-web's lives in apps.
        let rows = [
            KubeRowID(namespace: "argocd", name: "prod-team-1-acme-pay-service"), KubeRowID(namespace: "argocd", name: "acme-infra"),
            KubeRowID(namespace: "apps", name: "prod-team-4-acme-web"),
        ]
        let mode = KubeMarkedAppsMode.of(
            discovery: KubeDiscovery(kinds: [Self.applications]), applications: .acrossCluster(rows), marked: Set(apps.map(\.app.key)))
        guard case .beside = mode else { return XCTFail("\(mode)") }
        let derived = KubeMarkedSection.derived(apps, mode: mode, applications: .acrossCluster(rows))
        XCTAssertEqual(derived.shown, derived.beside, "among the Applications, their chip showing them alone")
        func tags(_ instance: String) -> [KubeGitOpsTag]? { derived.beside.first { $0.marked?.key.instance == instance }?.tags }
        XCTAssertNil(tags("prod-team-1-acme-pay-service"), "its Application is here")
        XCTAssertTrue(tags("prod-team-2-acme-cart-service")?.contains(.text("not in this cluster")) == true, "\(derived.beside.map(\.tags))")
        XCTAssertTrue(tags("prod-team-4-acme-web")?.contains(.text("may be apps/prod-team-4-acme-web")) == true, "a name match is never said missing")
        XCTAssertTrue(tags("prod-team-5-acme-ads-service")?.contains(.text("installation hub-b")) == true)
        func hover(_ instance: String) -> String { derived.beside.first { $0.marked?.key.instance == instance }?.hover ?? "" }
        XCTAssertTrue(hover("prod-team-2-acme-cart-service").contains("Its Application isn't in this cluster."))
        XCTAssertTrue(hover("prod-team-4-acme-web").contains("An Application of the same name lives in apps: it may be apps/prod-team-4-acme-web."))
        XCTAssertTrue(hover("prod-team-5-acme-ads-service").contains("Installation hub-b: can't tell whether it is this cluster's Argo CD"))
        XCTAssertEqual(derived.beside.count, 4)
        XCTAssertEqual(KubeMarkedSection.besideChip(derived.beside.count), "4 marked apps with no Application here")
        XCTAssertEqual(KubeMarkedSection.besideChip(1), "1 marked app with no Application here")
        let section = KubeGitOpsSection.rows(summaries: [], live: [:], listed: [], scope: .all, now: now, derived: derived)
        XCTAssertEqual(section.shown.count, 4)
        XCTAssertEqual(KubeGitOpsSection.visible(section, chip: nil, hideReady: true, tool: nil, notPlaced: false, beside: true, text: "").count, 4, "the chip shows them alone, Ready too")
        XCTAssertEqual(
            KubeMarkedSection.sectionHeader(
                mode: mode, argo: 2, flux: 0, summarisedAt: now.addingTimeInterval(-120), summarising: false, apps: apps.count, reading: whole(),
                readAt: now.addingTimeInterval(-120), now: now),
            "Argo CD 2 kinds · summarised 2m ago · marked apps read 2m ago")
    }

    /// R1's list across the cluster is never cut, R2's summaries are, at
    /// 500: a hub of 1,000 Applications still derives the marked apps it
    /// doesn't hold — presence is R1's (14.3).
    func testAThousandApplicationsListedStillDeriveTheMissing() {
        let rows = (0..<1000).map { KubeRowID(namespace: "argocd", name: "acme-app-\($0)") }
        var marked = Set((0..<990).map { KubeTrackingID.AppKey(installation: "", instance: "acme-app-\($0)") })
        let missing = (0..<12).map { KubeTrackingID.AppKey(installation: "", instance: "prod-team-\($0 % 10)-acme-extra-\($0)-service") }
        marked.formUnion(missing)
        let mode = KubeMarkedAppsMode.of(discovery: KubeDiscovery(kinds: [Self.applications]), applications: .acrossCluster(rows), marked: marked)
        guard case .beside(let coexistence) = mode else { return XCTFail("\(mode)") }
        XCTAssertEqual(coexistence.missing, Set(missing))
    }

    func testApplicationsReadOnlyInSomeNamespacesListOnlyWhatWasRead() {
        let apps = [
            deployment("team-a_prod-acme-pay", "acme-pay", namespace: "team-a", .healthy, "2/2 available"),
            deployment("team-b_prod-acme-cart", "acme-cart", namespace: "team-b", .healthy, "2/2 available"),
            deployment("prod-team-1-acme-web", "acme-web", .healthy, "2/2 available"),
        ]
        let read = KubeMarkedAppsMode.ApplicationsRead.namespaces(["team-a"], [KubeRowID(namespace: "team-a", name: "prod-acme-other")])
        let mode = KubeMarkedAppsMode.of(discovery: KubeDiscovery(kinds: [Self.applications]), applications: read, marked: Set(apps.map(\.app.key)))
        let derived = KubeMarkedSection.derived(apps, mode: mode, applications: read)
        XCTAssertEqual(derived.beside.map { $0.marked?.key.instance }, ["team-a_prod-acme-pay"], "only an ns_name mark whose namespace was read")
        XCTAssertEqual(derived.beside.first?.tags.last, .text("not where Applications were read"), "never \"not in this cluster\"")
        XCTAssertTrue(derived.beside.first?.hover.contains("Its Application wasn't found where Applications were read.") == true)
        XCTAssertEqual(derived.unread, 2)
        let lines = KubeMarkedSection.lines(mode: mode, context: "fake-prod", apps: apps.map(\.app), reading: whole(), tally: .init(), kinds: [], unread: derived.unread)
        XCTAssertEqual(lines.unread, "2 marked apps whose Application's namespace couldn't be read: not listed")
        XCTAssertNil(lines.lead, "Applications are the section's: no marks' lead")
    }

    func testBeforeROnesFirstListNothingIsDerived() {
        let apps = spoke()
        let mode = KubeMarkedAppsMode.of(discovery: KubeDiscovery(kinds: [Self.applications]), applications: .notYetListed, marked: Set(apps.map(\.app.key)))
        XCTAssertEqual(mode, .off)
        XCTAssertEqual(KubeMarkedSection.derived(apps, mode: mode, applications: .notYetListed), KubeMarkedSection.Derived(), "no row, no chip: not here can't be said yet")
        XCTAssertEqual(KubeMarkedAppsMode.of(discovery: nil, applications: .notYetListed, marked: Set(apps.map(\.app.key))), .off, "no discovery: nothing said")
    }

    func testFluxServedArgoNotBothAreShown() throws {
        let fake = FakeKubeAPI(socket: nil)
        fake.addGitOpsFixtures(now: now)
        var objects: [KubeGitOpsObject] = []
        for kind in KubeGitOpsSummary.summarised where kind.group.contains("fluxcd") {
            for name in fake.names(kind.fullName) {
                guard let whole = fake.object(kind.fullName, name, namespace: "flux-system") else { continue }
                if let object = try KubeGitOpsSummary.object(try JSONSerialization.data(withJSONObject: whole), readAt: now) { objects.append(object) }
            }
        }
        XCTAssertFalse(objects.isEmpty)
        let derived = KubeMarkedSection.derived(spoke(), mode: .only(.notServed), applications: .notYetListed)
        let rows = KubeGitOpsSection.rows(
            summaries: KubeGitOpsSummary.ranked(objects, now: now), live: [:], listed: [], scope: .all, now: now, derived: derived)
        XCTAssertTrue(rows.shown.contains { $0.tool == .flux })
        XCTAssertTrue(rows.shown.contains(where: \.isMarked))
        XCTAssertEqual(rows.shown.map(\.state), rows.shown.map(\.state).sorted(), "one order for both")
        XCTAssertEqual(
            KubeMarkedSection.sectionHeader(
                mode: .only(.notServed), argo: 0, flux: 6, summarisedAt: now.addingTimeInterval(-180), summarising: false, apps: 4, reading: whole(),
                readAt: now.addingTimeInterval(-30), now: now),
            "Argo CD: from marks · 4 apps · read just now · Flux 6 kinds · summarised 3m ago")
    }

    func testSeveralInstallationsAreSaid() {
        let apps = spoke().map(\.app) + [deployment("prod-team-5-acme-ads-service", "acme-ads", .healthy, "2/2 available", installation: "hub-b").app]
        XCTAssertEqual(KubeMarkedSection.installationsLine(apps), "2 Argo CD installations mark objects here: unnamed (4 apps), hub-b (1 app)")
        XCTAssertNil(KubeMarkedSection.installationsLine(spoke().map(\.app)))
    }

    // MARK: Filters, groupings

    func testIsMarksKindMarksImageToolAndRepo() {
        let derived = KubeMarkedSection.derived(spoke(), mode: .only(.notServed), applications: .notYetListed)
        var application = KubeGitOpsRow(
            id: "applications.argoproj.io/argocd/acme-shop", key: .init(kind: "Application", namespace: "argocd", name: "acme-shop"),
            resource: "applications.argoproj.io", ref: KubeRowID(namespace: "argocd", name: "acme-shop"), role: .application, tool: .argo, state: .ready,
            why: "Synced", summarised: true)
        application.grouping.repo = "git.acme.example/acme/fleet"
        application.source = "acme/fleet ./apps @main"
        let rows = KubeGitOpsSection.Rows(shown: derived.shown + [application])
        func visible(_ text: String) -> [String] {
            KubeGitOpsSection.visible(rows, chip: nil, hideReady: false, tool: nil, notPlaced: false, text: text).map(\.id)
        }
        let marked = derived.shown.map(\.id)
        XCTAssertEqual(Set(visible("is:marks")), Set(marked))
        XCTAssertEqual(visible("-is:marks"), [application.id])
        XCTAssertEqual(Set(visible("kind:marks")), Set(marked))
        XCTAssertEqual(visible("kind:app"), [application.id], "kind:app is Applications only")
        XCTAssertEqual(Set(visible("tool:argo")), Set(marked + [application.id]), "tool:argo keeps both")
        XCTAssertEqual(visible("repo:acme"), [application.id], "repo: matches no app read from marks — not even by its image")
        XCTAssertEqual(visible("image:acme-cart"), derived.shown.filter { $0.marked?.key.instance == "prod-team-2-acme-cart-service" }.map(\.id))
        XCTAssertTrue(visible("image:nope").isEmpty)
        XCTAssertNil(KubeGitOpsFilter("is:marks kind:marks image:x").refusal)
        XCTAssertFalse(KubeGitOpsFilter("is:marks").asksState, "is:marks asks no state: Hide Ready still hides")
        XCTAssertTrue(KubeGitOpsFilter("is:failed").asksState)
        XCTAssertEqual(KubeGitOpsFilter("is:nope").refusal, "Not read: is:nope — is: failed, blocked, stuck, drift, progressing, paused, ready, unknown, marks")
        XCTAssertEqual(
            KubeGitOpsSection.visible(rows, chip: nil, hideReady: true, tool: nil, notPlaced: false, text: "is:marks").contains { $0.state == .ready }, false)
    }

    func testGroupsByToolSourceDestinationOwnerAndInstallation() {
        let apps = spoke() + [deployment("prod-team-5-acme-ads-service", "acme-ads", namespace: "team-5", .healthy, "2/2 available", installation: "hub-b")]
        let rows = KubeMarkedSection.derived(apps, mode: .only(.notServed), applications: .notYetListed).shown
        let application = KubeGitOpsRow(
            id: "applications.argoproj.io/argocd/acme-shop", key: .init(kind: "Application", namespace: "argocd", name: "acme-shop"),
            resource: "applications.argoproj.io", ref: KubeRowID(namespace: "argocd", name: "acme-shop"), role: .application, tool: .argo, state: .ready,
            why: "Synced", summarised: true)
        let all = rows + [application]
        let tools = KubeGitOpsGrouping.groups(all, by: .tool, all: all)
        XCTAssertEqual(tools.map(\.title), ["Argo CD", "Argo CD (from marks)"])
        XCTAssertEqual(tools.last?.members.count, rows.count)
        let sources = KubeGitOpsGrouping.groups(rows, by: .source, all: rows)
        XCTAssertTrue(sources.contains { $0.title == "registry.acme.example/acme/acme-pay" }, "by image repository: \(sources.map(\.title))")
        let destinations = KubeGitOpsGrouping.groups(rows, by: .destination, all: rows)
        XCTAssertTrue(destinations.contains { $0.title == "team-2" }, "\(destinations.map(\.title))")
        let owners = KubeGitOpsGrouping.groups(rows, by: .owner, all: rows)
        XCTAssertEqual(owners.map(\.title), ["No owner"], "never an owner")
        let installations = KubeGitOpsGrouping.groups(all, by: .installation, all: all)
        XCTAssertEqual(installations.map(\.title), ["No installation id", "Installation hub-b", "Argo CD's and Flux's own objects"])
        XCTAssertEqual(installations.last?.rest, true)
        // Offered only while several installations mark objects here.
        XCTAssertEqual(KubeGitOpsGroupBy.destination.next(installations: true), .installation)
        XCTAssertEqual(KubeGitOpsGroupBy.installation.next(installations: true), KubeGitOpsGroupBy.none)
        XCTAssertEqual(KubeGitOpsGroupBy.destination.next(installations: false), KubeGitOpsGroupBy.none)
        XCTAssertEqual(KubeGitOpsGroupBy.installation.next(installations: false), KubeGitOpsGroupBy.none, "no longer offered: back to none")
        XCTAssertFalse(KubeGitOpsGroupBy.offered(installations: false).contains(.installation))
    }

    // MARK: k, the detail

    func testKCopiesArgocdAgainstThePersonsServerNeverCore() {
        let plain = KubeMarkedSection.row(deployment("prod-team-1-acme-pay-service", "acme-pay", .healthy, "2/2 available"), installations: false)
        XCTAssertEqual(KubeGitOpsSection.cliLine(plain, context: "fake-prod"), "argocd app get prod-team-1-acme-pay-service")
        let namespaced = KubeMarkedSection.row(deployment("apps_prod-acme-cart", "acme-cart", .healthy, "2/2 available"), installations: false)
        XCTAssertEqual(KubeGitOpsSection.cliLine(namespaced, context: "fake-prod"), "argocd app get prod-acme-cart --app-namespace apps")
        for row in [plain, namespaced] {
            let line = KubeGitOpsSection.cliLine(row, context: "fake-prod") ?? ""
            XCTAssertFalse(line.contains("--core") || line.contains("--kube-context") || line.contains("fake-prod"), line)
        }
        // A cluster's `--core` is no app: the parser refuses it, the instance
        // labels too, and the line never carries an argument argocd could
        // read as an option.
        XCTAssertNil(KubeTrackingID.parse("--core:apps/Deployment:team/web"))
        XCTAssertNil(KubeTrackingID.parse("team_--insecure:apps/Deployment:team/web"))
        XCTAssertNil(KubeTrackingID.instanceLabel("--core"))
        for forged in ["--core", "team_--insecure", "-x", "_x", "team_", "a_b_c"] {
            var row = plain
            row.marked?.key = .init(installation: "", instance: forged)
            XCTAssertNil(KubeGitOpsSection.cliLine(row, context: "fake-prod"), forged)
        }
    }

    func testTheDetailSaysWhyTheApplicationsVerbsArentHere() {
        let app = spoke()[0]
        let detail = KubeMarkedAppDetail.make(app, mode: .only(.notServed), context: "fake-prod")
        XCTAssertEqual(detail.absent, "Sync, Refresh, Rollback and Diff act on the Application, which is in Argo CD's cluster — not in your kubeconfig. Use Argo CD there.")
        XCTAssertEqual(detail.lead, "Argo CD runs in another cluster — not in your kubeconfig.")
        XCTAssertEqual(detail.word, app.health.word)
        XCTAssertTrue(detail.facts.contains("Namespaces: team-2"), "\(detail.facts)")
        XCTAssertEqual(
            KubeMarkedSection.absentVerbs(.only(.noApplications), context: "fake-dev"),
            "Sync, Refresh, Rollback and Diff act on the Application, which isn't in this cluster. Use the Argo CD that deploys these.")
        XCTAssertFalse(KubeMarkedSection.absentVerbs(.only(.forbidden), context: "fake-prod").contains("another cluster"))
        XCTAssertFalse(KubeMarkedSection.absentVerbs(.only(.undiscovered), context: "fake-prod").contains("Argo CD's cluster"))
    }

    func testImagesShortAndTheirRepository() {
        XCTAssertEqual(KubeMarkedSection.shortImage("registry.acme.example/acme/checkout-api:4.12.0"), "…/checkout-api:4.12.0")
        XCTAssertEqual(KubeMarkedSection.shortImage("nginx:1.27"), "nginx:1.27")
        XCTAssertEqual(KubeMarkedSection.repository("registry.acme.example:5000/acme/web:4.12.0"), "registry.acme.example:5000/acme/web")
        XCTAssertEqual(KubeMarkedSection.repository("registry.acme.example/acme/web@sha256:" + String(repeating: "a", count: 64)), "registry.acme.example/acme/web")
        XCTAssertEqual(KubeMarkedSection.source([]), "")
    }

    private static let applications = KubeResourceKind(
        group: "argoproj.io", version: "v1alpha1", resource: "applications", kind: "Application", singular: "application", namespaced: true,
        verbs: ["get", "list", "watch"])
}
