import Foundation
import XCTest

@testable import Overterm

/// Argo CD's and Flux's objects summarised (docs/design/kubernetes/
/// gitops.md, 2.3–2.5, 8.1): every fixture of `FakeKubeAPI+GitOps` on its
/// rung of the ladder, each rule in evaluation order, the time edges moved
/// by the tick alone, the last error's order, managedFields' times, and the
/// scope rule. Pure: the fake's objects are read as a GET answers them,
/// without a server.
final class KubeGitOpsSummaryTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)
    private let c = FakeKubeAPI.GitOpsCommit.self

    /// Every object the fixtures hold, summarised and ranked at `now`.
    private func fixtures() throws -> [KubeGitOpsObject] {
        let fake = FakeKubeAPI(socket: nil)
        fake.addGitOpsFixtures(now: now)
        var objects: [KubeGitOpsObject] = []
        for kind in KubeGitOpsSummary.summarised {
            for name in fake.names(kind.fullName) {
                for namespace in ["argocd", "team-a", "flux-system"] {
                    guard let whole = fake.object(kind.fullName, name, namespace: namespace) else { continue }
                    let data = try JSONSerialization.data(withJSONObject: whole)
                    objects.append(try XCTUnwrap(try KubeGitOpsSummary.object(data, readAt: now), "\(kind.fullName) \(name)"))
                }
            }
        }
        return KubeGitOpsSummary.ranked(objects, now: now)
    }

    private func find(_ objects: [KubeGitOpsObject], _ kind: String, _ name: String, in namespace: String? = nil) throws -> KubeGitOpsObject {
        try XCTUnwrap(objects.first { $0.kind == kind && $0.ref.name == name && (namespace == nil || $0.ref.namespace == namespace) }, "\(kind) \(name)")
    }

    private func stamp(_ seconds: TimeInterval) -> String { FakeKubeAPI.time(now.addingTimeInterval(-seconds)) }

    private func object(_ dict: [String: Any]) throws -> KubeGitOpsObject {
        try XCTUnwrap(KubeGitOpsSummary.object(dict, readAt: now))
    }

    private func application(spec: [String: Any] = [:], status: [String: Any]) -> [String: Any] {
        [
            "apiVersion": "argoproj.io/v1alpha1", "kind": "Application", "metadata": ["name": "acme-shop", "namespace": "argocd"],
            "spec": ["destination": ["namespace": "shop"]].merging(spec) { $1 }, "status": status,
        ]
    }

    private func kustomization(_ name: String = "acme-apps", spec: [String: Any] = [:], status: [String: Any], metadata: [String: Any] = [:]) -> [String: Any] {
        [
            "apiVersion": "kustomize.toolkit.fluxcd.io/v1", "kind": "Kustomization",
            "metadata": ["name": name, "namespace": "flux-system"].merging(metadata) { $1 },
            "spec": ["interval": "5m", "path": "./apps", "sourceRef": ["kind": "GitRepository", "name": "acme-fleet"]].merging(spec) { $1 },
            "status": status,
        ]
    }

    private func ready(_ status: String, _ reason: String, _ message: String = "", ago: TimeInterval = 60) -> [String: Any] {
        FakeKubeAPI.condition("Ready", status, reason, message, since: now.addingTimeInterval(-ago))
    }

    private func state(_ dict: [String: Any], at time: Date? = nil, peers: [[String: Any]] = []) throws -> KubeGitOpsVerdict {
        let objects = try ([dict] + peers).map(object)
        var all: KubeGitOpsLadder.Peers = [:]
        for object in objects { all[object.key] = object }
        return KubeGitOpsLadder.evaluate(objects[0], now: time ?? now, peers: all)
    }

    // MARK: The fixtures

    func testEveryFixtureStandsOnItsRung() throws {
        let all = try fixtures()
        func check(_ kind: String, _ name: String, in namespace: String? = nil, _ state: KubeGitOpsState, _ why: String? = nil, line: UInt = #line) throws {
            let object = try find(all, kind, name, in: namespace)
            XCTAssertEqual(object.state, state, "\(kind) \(name): \(object.why)", line: line)
            if let why { XCTAssertEqual(object.why, why, line: line) }
        }
        try check("Application", "acme-shop-prod", .ready, "Synced, Healthy")
        try check("Application", "acme-api", in: "team-a", .failed, "Degraded")
        try check(
            "Application", "acme-web", .failed,
            "auto-sync failed for 77e1a02 and won't retry it: one or more synchronization tasks completed unsuccessfully")
        try check("Application", "acme-new", .progressing, "syncing 77e1a02 40s")
        try check("Application", "globex-batch", .stuck, "syncing 26m: waiting for completion of hook batch/Job/migrate")
        try check("Application", "acme-admin", .drift, "OutOfSync, auto-sync off")
        try check("Application", "acme-old-fail", .ready)
        try check("Application", "acme-remote", .ready)
        try check("ApplicationSet", "acme-envs", .ready)
        try check("ApplicationSet", "globex-broken-set", .failed, "failed to get params for generator: repo not found")
        try check("GitRepository", "acme-fleet", .ready, "fetched main@a77b0d1")
        try check("GitRepository", "acme-broken", .failed)
        try check("Kustomization", "acme-apps", .ready, "applied main@a77b0d1")
        try check("Kustomization", "acme-cron", .failed, "main@c03f9aa failed (BuildFailed); main@a77b0d1 still applied")
        try check("Kustomization", "acme-infra", .failed)
        try check("Kustomization", "acme-web", .blocked, "dependency acme-infra: HealthCheckFailed")
        try check("Kustomization", "acme-api", .blocked, "source acme-broken: AuthenticationFailed")
        try check("Kustomization", "acme-jobs", .paused, "suspended 12d ago by overterm")
        try check("Kustomization", "globex-remote", .ready)
        try check("HelmRelease", "globex-redis", .failed)
        try check("HelmRelease", "acme-payments", .failed, "upgrade to 1.5.0 failed; rolled back to 1.4.2")
        try check("HelmChart", "flux-system-acme-payments", .ready)
        try check("OCIRepository", "acme-manifests", .ready, "fetched sha256:1f2e3d4")

        // Tags beside a state, never instead of one.
        XCTAssertEqual(try find(all, "Kustomization", "acme-jobs").tags, [.last("HealthCheckFailed")], "Paused keeps what its conditions say")
        XCTAssertTrue(try find(all, "Application", "acme-admin").tags.contains(.manual))
        let old = try find(all, "Application", "acme-old-fail")
        XCTAssertTrue(old.tags.contains(.lastSyncFailed(now.addingTimeInterval(-2 * 86_400))), "a failed sync of an older revision is a tag")
        XCTAssertEqual(old.tags.first { if case .lastSyncFailed = $0 { true } else { false } }?.said(now: now), "last sync failed 2d ago")
        XCTAssertEqual(try find(all, "Application", "acme-remote").remote, "https://fake-prod.example:6443")
        XCTAssertEqual(try find(all, "Kustomization", "globex-remote").remote, "spec.kubeConfig.secretRef globex-edge-kubeconfig")
        let api = try find(all, "Application", "acme-api")
        XCTAssertTrue(api.healthElsewhere, "Argo CD 3's appTree")
        XCTAssertEqual(api.tags.filter { [.multiSource, .valuesRef].contains($0) }, [.multiSource, .valuesRef])
        XCTAssertEqual(api.revisions.wanted, ["1.5.0", c.target], "multi-source: one revision a source")
        XCTAssertEqual(KubeGitOpsRevision.column(api), "→ 1.5.0 · 77e1a02", "nothing applied yet")
        XCTAssertEqual(KubeGitOpsRevision.column(try find(all, "Application", "acme-web")), "5d0c1e2 → 77e1a02", "live → target while OutOfSync")

        // Problems first, then the oldest.
        let order = all.map(\.state)
        XCTAssertEqual(order, order.sorted(), "display order")
        XCTAssertEqual(all.first?.state, .failed)
        let counts = KubeGitOpsSummary.counts(all)
        XCTAssertEqual(counts[.blocked], 2)
        XCTAssertEqual(counts[.paused], 1)
    }

    /// A controller that is down changes no state: its rows "may be stale".
    func testAControllerDownTagsItsToolsRows() throws {
        let fake = FakeKubeAPI(socket: nil)
        fake.addGitOpsFixtures(now: now)
        let data = try JSONSerialization.data(withJSONObject: XCTUnwrap(fake.object("kustomizations.kustomize.toolkit.fluxcd.io", "acme-apps", namespace: "flux-system")))
        let apps = try XCTUnwrap(KubeGitOpsSummary.object(data, readAt: now))
        let ranked = KubeGitOpsSummary.ranked([apps], now: now, stale: [.flux])
        XCTAssertEqual(ranked[0].state, .ready)
        XCTAssertEqual(ranked[0].tags, [.mayBeStale])
        // An Application Argo CD hasn't reconciled for 40 minutes.
        let stale = try object(application(status: ["sync": ["status": "Synced"], "health": ["status": "Healthy"], "reconciledAt": stamp(2400)]))
        XCTAssertEqual(KubeGitOpsLadder.evaluate(stale, now: now).tags.last?.said(now: now), "not reconciled for 40m")
    }

    // MARK: Each rule, in evaluation order

    func testArgoCDsRules() throws {
        let auto: [String: Any] = ["syncPolicy": ["automated": ["prune": false]]]
        // Failed: an *Error condition first.
        var verdict = try state(
            application(status: [
                "sync": ["status": "OutOfSync"], "health": ["status": "Healthy"],
                "conditions": [["type": "ComparisonError", "message": "rpc error: repository not accessible"]],
            ]))
        XCTAssertEqual(verdict.state, .failed)
        XCTAssertEqual(verdict.why, "ComparisonError: rpc error: repository not accessible")
        // Missing while Synced is Failed; Missing with OutOfSync goes through OutOfSync's rules.
        XCTAssertEqual(try state(application(status: ["sync": ["status": "Synced"], "health": ["status": "Missing"]])).state, .failed)
        verdict = try state(
            application(
                spec: auto,
                status: [
                    "sync": ["status": "OutOfSync", "revision": c.target], "health": ["status": "Missing"],
                    "operationState": ["phase": "Running", "startedAt": stamp(30), "syncResult": ["revision": c.target]],
                ]))
        XCTAssertEqual(verdict.state, .progressing, "a new Application before its first sync isn't Failed")
        // Retries: Failed while it retries.
        verdict = try state(
            application(
                spec: auto,
                status: [
                    "sync": ["status": "OutOfSync", "revision": c.target], "health": ["status": "Healthy"],
                    "operationState": ["phase": "Running", "startedAt": stamp(120), "retryCount": 2, "message": "retrying: one or more objects failed"],
                ]))
        XCTAssertEqual(verdict.state, .failed)
        XCTAssertEqual(verdict.why, "retrying (attempt 3): retrying: one or more objects failed")
        // A failed operation for the current revision: auto-sync won't retry it, unless retry is set.
        let failedOperation: [String: Any] = [
            "sync": ["status": "OutOfSync", "revision": c.target], "health": ["status": "Healthy"],
            "operationState": ["phase": "Failed", "finishedAt": stamp(300), "message": "hook failed", "syncResult": ["revision": c.target]],
        ]
        XCTAssertEqual(try state(application(spec: auto, status: failedOperation)).why, "auto-sync failed for 77e1a02 and won't retry it: hook failed")
        XCTAssertEqual(
            try state(application(spec: ["syncPolicy": ["automated": [String: Any](), "retry": ["limit": 5]]], status: failedOperation)).why,
            "sync failed for 77e1a02: hook failed")
        // Terminating past ten minutes: Stuck.
        verdict = try state(
            application(status: ["sync": ["status": "Synced"], "health": ["status": "Healthy"], "operationState": ["phase": "Terminating", "startedAt": stamp(900)]]))
        XCTAssertEqual(verdict.state, .stuck)
        XCTAssertEqual(verdict.why, "terminating 15m")
        // Drift: the last operation already synced this revision and succeeded.
        verdict = try state(
            application(
                spec: auto,
                status: [
                    "sync": ["status": "OutOfSync", "revision": c.target], "health": ["status": "Healthy"],
                    "operationState": ["phase": "Succeeded", "finishedAt": stamp(60), "syncResult": ["revision": c.target]],
                ]))
        XCTAssertEqual(verdict.state, .drift)
        XCTAssertEqual(verdict.why, "OutOfSync after syncing 77e1a02: self-heal is off, or a difference isn't ignored")
        // Drift: resources that need pruning, prune off.
        verdict = try state(
            application(
                spec: auto,
                status: [
                    "sync": ["status": "OutOfSync", "revision": c.target], "health": ["status": "Healthy"],
                    "resources": [
                        ["kind": "ConfigMap", "name": "a", "namespace": "shop", "status": "OutOfSync", "requiresPruning": true],
                        ["kind": "ConfigMap", "name": "b", "namespace": "shop", "status": "OutOfSync", "requiresPruning": true],
                        ["kind": "Deployment", "name": "web", "namespace": "shop", "status": "Synced"],
                    ],
                ]))
        XCTAssertEqual(verdict.state, .drift)
        XCTAssertEqual(verdict.why, "2 resources need pruning; prune is off")
        // `automated.enabled: false` is auto-sync off.
        XCTAssertEqual(
            try state(application(spec: ["syncPolicy": ["automated": ["enabled": false]]], status: ["sync": ["status": "OutOfSync"], "health": ["status": "Healthy"]]))
                .why, "OutOfSync, auto-sync off")
        // Suspended health is Ready, said so; sync Unknown is Unknown.
        XCTAssertEqual(try state(application(status: ["sync": ["status": "Synced"], "health": ["status": "Suspended"]])).why, "Synced, Suspended")
        XCTAssertEqual(try state(application(status: ["sync": ["status": "Unknown"], "health": ["status": "Healthy"]])).state, .unknown)
    }

    func testFluxsRules() throws {
        let source: [String: Any] = [
            "apiVersion": "source.toolkit.fluxcd.io/v1", "kind": "GitRepository", "metadata": ["name": "acme-fleet", "namespace": "flux-system"],
            "spec": ["url": "https://git.acme.example/acme/shop.git", "interval": "1m"],
            "status": ["conditions": [ready("True", "Succeeded")], "artifact": ["revision": "main@sha1:\(c.target)", "lastUpdateTime": stamp(30)]],
        ]
        // Paused before Failed, the old state a tag.
        let paused = try state(kustomization(spec: ["suspend": true], status: ["conditions": [ready("False", "BuildFailed")]]))
        XCTAssertEqual(paused.state, .paused)
        XCTAssertEqual(paused.tags, [.last("BuildFailed")])
        // Stalled, and retrying, are Failed.
        let stalled = try state(
            kustomization(status: [
                "conditions": [ready("Unknown", "Progressing"), FakeKubeAPI.condition("Stalled", "True", "InvalidPath", "path not found", since: now)]
            ]))
        XCTAssertEqual(stalled.state, .failed)
        XCTAssertEqual(stalled.why, "stalled: InvalidPath: path not found")
        let retrying = try state(
            kustomization(status: [
                "conditions": [ready("Unknown", "Progressing"), FakeKubeAPI.condition("Reconciling", "True", "ProgressingWithRetry", "timeout waiting", since: now)]
            ]))
        XCTAssertEqual(retrying.why, "retrying after: timeout waiting")
        // An unknown reason is Failed too.
        XCTAssertEqual(try state(kustomization(status: ["conditions": [ready("False", "SomethingNew", "eh")]])).state, .failed)
        // A HelmRelease whose latest release failed.
        let release: [String: Any] = [
            "apiVersion": "helm.toolkit.fluxcd.io/v2", "kind": "HelmRelease", "metadata": ["name": "acme-web", "namespace": "flux-system"],
            "spec": ["chart": ["spec": ["chart": "web", "sourceRef": ["kind": "HelmRepository", "name": "acme"]]]],
            "status": ["conditions": [ready("True", "UpgradeSucceeded")], "history": [["chartVersion": "2.0.0", "status": "failed"]]],
        ]
        XCTAssertEqual(try state(release).why, "2.0.0 failed")
        // Stuck past max(2 × interval, 5 min); Progressing within it — the edge moved by the tick alone.
        let reconciling = kustomization(
            spec: ["interval": "5m"],
            status: ["conditions": [ready("Unknown", "Progressing"), FakeKubeAPI.condition("Reconciling", "True", "Progressing", "applying", since: now.addingTimeInterval(-590))]])
        XCTAssertEqual(try state(reconciling).state, .progressing)
        XCTAssertEqual(try state(reconciling, at: now.addingTimeInterval(20)).state, .stuck, "10 minutes passed with no new input")
        XCTAssertEqual(try state(reconciling, at: now.addingTimeInterval(20)).why, "reconciling for 10m: applying")
        // A source's artifact that differs from what was attempted: Progressing, then Drift past interval + retryInterval.
        let behind = kustomization(
            spec: ["interval": "5m", "retryInterval": "1m"],
            status: [
                "conditions": [ready("True", "ReconciliationSucceeded")], "lastAppliedRevision": "main@sha1:\(c.applied)",
                "lastAttemptedRevision": "main@sha1:\(c.applied)",
            ])
        XCTAssertEqual(try state(behind, peers: [source]).state, .progressing)
        let late = try state(behind, at: now.addingTimeInterval(400), peers: [source])
        XCTAssertEqual(late.state, .drift)
        XCTAssertEqual(late.why, "fetched main@77e1a02, not applied; main@a77b0d1 applied")
        // observedGeneration behind: Progressing for a minute, timed from managedFields, then Unknown.
        let lagging = kustomization(
            status: ["conditions": [ready("True", "ReconciliationSucceeded")], "observedGeneration": 3],
            metadata: [
                "generation": 4,
                "managedFields": [
                    ["manager": "kubectl", "operation": "Update", "time": stamp(30), "fieldsV1": ["f:spec": ["f:path": [String: Any]()]]],
                    ["manager": "kustomize-controller", "operation": "Update", "time": stamp(10), "fieldsV1": ["f:status": [String: Any]()]],
                ],
            ])
        XCTAssertEqual(try object(lagging).generationChangedAt, now.addingTimeInterval(-30), "the newest entry that owns spec")
        XCTAssertEqual(try state(lagging).state, .progressing)
        XCTAssertEqual(try state(lagging, at: now.addingTimeInterval(60)).state, .unknown)
        XCTAssertEqual(try state(lagging, at: now.addingTimeInterval(60)).why, "not yet looked at (generation 4, last looked at 3)")
        // A dependency chain followed among the summaries.
        let infra = kustomization("acme-infra", spec: ["dependsOn": [["name": "cert-manager"]]], status: ["conditions": [ready("False", "DependencyNotReady")]])
        let certManager = kustomization("cert-manager", status: ["conditions": [ready("False", "HealthCheckFailed")]])
        let web = kustomization("acme-web", spec: ["dependsOn": [["name": "acme-infra"]]], status: ["conditions": [ready("False", "DependencyNotReady", "dependency not ready")]])
        XCTAssertEqual(try state(web, peers: [infra, certManager]).why, "dependency acme-infra ← cert-manager: HealthCheckFailed")
        XCTAssertEqual(try state(web).why, "dependency not ready: dependency not ready", "nothing summarised to follow: no GET")
    }

    /// Argo CD's two edges, moved by the tick alone (8.1): auto-sync not
    /// started within the 3-minute reconcile period is Drift; an operation
    /// Running past 10 minutes is Stuck. The same input on each side.
    func testArgoCDsEdgesMoveWithTheTick() throws {
        let auto: [String: Any] = ["syncPolicy": ["automated": ["prune": false]]]
        // The last operation, for an older revision, finished 170 s ago.
        let notStarted = application(
            spec: auto,
            status: [
                "sync": ["status": "OutOfSync", "revision": c.target], "health": ["status": "Healthy"],
                "operationState": ["phase": "Succeeded", "finishedAt": stamp(170), "syncResult": ["revision": c.older]],
            ])
        let before = try state(notStarted)
        XCTAssertEqual(before.state, .progressing)
        XCTAssertEqual(before.why, "auto-sync on, syncing 77e1a02 soon")
        let after = try state(notStarted, at: now.addingTimeInterval(20))
        XCTAssertEqual(after.state, .drift, "3 minutes passed with no new input")
        XCTAssertEqual(after.why, "auto-sync on, not started for 77e1a02")
        XCTAssertEqual(after.since, now.addingTimeInterval(-170))
        // A Running operation started 590 s ago.
        let running = application(
            spec: auto,
            status: [
                "sync": ["status": "OutOfSync", "revision": c.target], "health": ["status": "Healthy"],
                "operationState": ["phase": "Running", "startedAt": stamp(590), "syncResult": ["revision": c.target]],
            ])
        let syncing = try state(running)
        XCTAssertEqual(syncing.state, .progressing)
        XCTAssertEqual(syncing.why, "syncing 77e1a02 9m50s")
        let stuck = try state(running, at: now.addingTimeInterval(20))
        XCTAssertEqual(stuck.state, .stuck, "10 minutes passed with no new input")
        XCTAssertEqual(stuck.why, "syncing 10m")
        XCTAssertEqual(stuck.since, now.addingTimeInterval(-590))
    }

    /// A row's Why is one line of at most 300 characters (2.2 column 5,
    /// 5.3), whatever the messages it quotes — kept at the hover's 4 KB,
    /// several lines when a manifest was cut from them — and so is the
    /// Overview's K602/K603 sentence built from it.
    func testWhyIsOneShortLine() throws {
        let long = (1...40).map { "line \($0): the webhook admission.acme.example denied the request for a reason that goes on" }.joined(separator: "\n")
        let degraded = application(status: ["sync": ["status": "Synced"], "health": ["status": "Degraded", "message": long]])
        let failed = application(
            spec: ["syncPolicy": ["automated": ["prune": false]]],
            status: [
                "sync": ["status": "OutOfSync", "revision": c.target], "health": ["status": "Healthy", "message": long],
                "operationState": ["phase": "Failed", "finishedAt": stamp(60), "message": long, "syncResult": ["revision": c.target]],
            ])
        XCTAssertGreaterThan(try object(failed).operation?.message?.count ?? 0, KubeGitOpsMessage.rowLimit, "the hover keeps more")
        XCTAssertTrue(try object(failed).operation?.message?.contains("\n") ?? false)
        for (dict, state) in [(degraded, KubeGitOpsState.failed), (failed, .failed)] {
            let verdict = try self.state(dict)
            XCTAssertEqual(verdict.state, state)
            XCTAssertLessThanOrEqual(verdict.why.count, KubeGitOpsMessage.rowLimit, verdict.why)
            XCTAssertFalse(verdict.why.contains("\n"), verdict.why)
            XCTAssertTrue(verdict.why.hasSuffix("…"), verdict.why)
            let finding = try XCTUnwrap(KubeHealth.object(dict, now: now).first { $0.check == .argoDegraded })
            XCTAssertFalse(finding.sentence.contains("\n"), finding.sentence)
            XCTAssertLessThanOrEqual(finding.sentence.count, KubeGitOpsMessage.rowLimit + "Failed: ".count)
        }
        XCTAssertTrue(try state(failed).why.hasPrefix("auto-sync failed for 77e1a02 and won't retry it: line 1: the webhook"))
    }

    /// A HelmRelease's chart fetched a version it hasn't attempted (2.3
    /// rules 5 and 6): Progressing, then Drift past interval +
    /// retryInterval. A `chartRef` OCIRepository's by its digest.
    func testAHelmReleasesChartFetchedNotApplied() throws {
        func release(_ spec: [String: Any], attempted: String, digest: String? = nil) -> [String: Any] {
            var status: [String: Any] = [
                "conditions": [ready("True", "UpgradeSucceeded")], "lastAttemptedRevision": attempted,
                "history": [["chartVersion": "2.0.0", "status": "deployed"]],
            ]
            if let digest { status["lastAttemptedRevisionDigest"] = digest }
            return [
                "apiVersion": "helm.toolkit.fluxcd.io/v2", "kind": "HelmRelease", "metadata": ["name": "acme-web", "namespace": "flux-system"],
                "spec": ["interval": "5m", "retryInterval": "1m"].merging(spec) { $1 }, "status": status,
            ]
        }
        let template: [String: Any] = ["chart": ["spec": ["chart": "web", "sourceRef": ["kind": "HelmRepository", "name": "acme"]]]]
        let chart: [String: Any] = [
            "apiVersion": "source.toolkit.fluxcd.io/v1", "kind": "HelmChart", "metadata": ["name": "flux-system-acme-web", "namespace": "flux-system"],
            "spec": ["chart": "web", "sourceRef": ["kind": "HelmRepository", "name": "acme"], "interval": "5m"],
            "status": ["conditions": [ready("True", "ChartPullSucceeded")], "artifact": ["revision": "2.1.0", "lastUpdateTime": stamp(30)]],
        ]
        let behind = release(template, attempted: "2.0.0")
        let fetching = try state(behind, peers: [chart])
        XCTAssertEqual(fetching.state, .progressing)
        XCTAssertEqual(fetching.why, "fetched 2.1.0, applying it")
        let late = try state(behind, at: now.addingTimeInterval(400), peers: [chart])
        XCTAssertEqual(late.state, .drift)
        XCTAssertEqual(late.why, "fetched 2.1.0, not applied; 2.0.0 deployed")
        XCTAssertEqual(try state(release(template, attempted: "2.1.0"), at: now.addingTimeInterval(400), peers: [chart]).state, .ready)

        // chartRef: an OCIRepository's `<tag>@sha256:…` against lastAttemptedRevisionDigest.
        let fetched = String(repeating: "1f2e3d4c", count: 8)
        let tried = String(repeating: "9a8b7c6d", count: 8)
        let oci: [String: Any] = [
            "apiVersion": "source.toolkit.fluxcd.io/v1", "kind": "OCIRepository", "metadata": ["name": "acme-web-chart", "namespace": "flux-system"],
            "spec": ["url": "oci://ghcr.io/acme/charts/web", "interval": "5m"],
            "status": ["conditions": [ready("True", "Succeeded")], "artifact": ["revision": "latest@sha256:\(fetched)", "lastUpdateTime": stamp(30)]],
        ]
        let reference: [String: Any] = ["chartRef": ["kind": "OCIRepository", "name": "acme-web-chart"]]
        let drifted = try state(release(reference, attempted: "2.0.0", digest: "sha256:\(tried)"), at: now.addingTimeInterval(400), peers: [oci])
        XCTAssertEqual(drifted.state, .drift)
        XCTAssertEqual(drifted.why, "fetched sha256:1f2e3d4, not applied; 2.0.0 deployed")
        XCTAssertEqual(
            try state(release(reference, attempted: "2.0.0", digest: "sha256:\(fetched)"), at: now.addingTimeInterval(400), peers: [oci]).state, .ready,
            "a tag isn't the chart's version: the digest says it was attempted")
        XCTAssertEqual(
            try state(release(reference, attempted: "2.0.0"), at: now.addingTimeInterval(400), peers: [oci]).state, .ready, "no digest: nothing said")
    }

    /// suspendedAt from managedFields: the newest entry owning spec.suspend.
    func testSuspendedSinceAndByWhom() throws {
        let all = try fixtures()
        let jobs = try find(all, "Kustomization", "acme-jobs")
        XCTAssertEqual(jobs.suspension, KubeGitOpsObject.Suspension(at: now.addingTimeInterval(-12 * 86_400), by: "overterm"))
        XCTAssertEqual(jobs.stateSince, now.addingTimeInterval(-12 * 86_400))
    }

    // MARK: The last error

    func testTheLastErrorsOrder() throws {
        let argo = try object(
            application(status: [
                "sync": ["status": "OutOfSync"], "health": ["status": "Degraded", "message": "health says"],
                "conditions": [["type": "SharedResourceWarning", "message": "shared"], ["type": "SyncError", "message": "the error"]],
                "operationState": ["phase": "Failed", "message": "the operation"],
            ]))
        XCTAssertEqual(argo.lastError, "the error", "an *Error condition first")
        let operation = try object(
            application(status: [
                "health": ["status": "Degraded", "message": "health says"],
                "operationState": [
                    "phase": "Error", "message": "the operation",
                    "syncResult": ["resources": [["kind": "Deployment", "name": "ok", "status": "Synced"], ["kind": "Deployment", "name": "acme-web", "status": "SyncFailed", "message": "denied"]]],
                ],
            ]))
        XCTAssertEqual(operation.lastError, "the operation — Deployment/acme-web: denied", "then the operation's, with the first resource that failed")
        XCTAssertEqual(try object(application(status: ["health": ["status": "Degraded", "message": "health says"]])).lastError, "health says")
        XCTAssertEqual(
            try object(application(status: ["conditions": [["type": "OrphanedResourceWarning", "message": "3 orphans"]]])).lastError,
            "OrphanedResourceWarning: 3 orphans")
        let flux = try object(
            kustomization(status: [
                "conditions": [
                    FakeKubeAPI.condition("Reconciling", "True", "ProgressingWithRetry", "retrying", since: now),
                    FakeKubeAPI.condition("Stalled", "True", "InvalidPath", "no path", since: now), ready("False", "BuildFailed", "the build"),
                ]
            ]))
        XCTAssertEqual(flux.lastError, "BuildFailed: the build", "Flux: Ready False first")
        XCTAssertEqual(
            try object(kustomization(status: ["conditions": [FakeKubeAPI.condition("Stalled", "True", "InvalidPath", "no path", since: now)]])).lastError,
            "InvalidPath: no path")
        let long = try object(kustomization(status: ["conditions": [ready("False", "BuildFailed", String(repeating: "x", count: 1000))]]))
        XCTAssertEqual(long.lastError?.count, KubeGitOpsMessage.rowLimit, "300 characters in a row")
    }

    // MARK: Scope

    func testScopeIsWhereItLivesOrWhatItDeploysInto() throws {
        let all = try fixtures()
        func names(_ scope: KubeScope) -> Set<String> { Set(KubeGitOpsSummary.kept(all, scope: scope).map { "\($0.kind) \($0.ref.name)" }) }
        let shop = names(.namespace("shop"))
        XCTAssertTrue(shop.contains("Application acme-shop-prod"), "by what it manages there")
        XCTAssertTrue(shop.contains("Kustomization acme-apps"), "a flux-system Kustomization with no targetNamespace, by its inventory")
        XCTAssertTrue(shop.contains("Application acme-admin"), "nothing applied yet: by its in-cluster destination")
        XCTAssertTrue(shop.contains("Kustomization acme-cron"), "a targetNamespace before anything is applied")
        XCTAssertTrue(shop.contains("HelmRelease acme-payments"))
        XCTAssertFalse(shop.contains("Application acme-remote"), "deploys to another cluster: by its own namespace only")
        XCTAssertFalse(shop.contains("Kustomization globex-remote"))
        XCTAssertTrue(shop.contains("GitRepository acme-fleet"), "a source a kept object takes from")
        XCTAssertTrue(shop.contains("GitRepository acme-broken"))
        XCTAssertTrue(shop.contains("HelmChart flux-system-acme-payments"), "a HelmRelease's chart")
        XCTAssertTrue(shop.contains("HelmRepository acme-charts"), "and the chart's source")
        XCTAssertTrue(shop.contains("OCIRepository globex-charts"), "a chartRef")
        XCTAssertFalse(shop.contains("OCIRepository acme-manifests"), "a source nobody kept uses")
        XCTAssertFalse(shop.contains("ApplicationSet acme-envs"))
        let dev = names(.namespace("envs-dev"))
        XCTAssertTrue(dev.contains("Application acme-envs-dev"))
        XCTAssertTrue(dev.contains("ApplicationSet acme-envs"), "an ApplicationSet whose Applications are kept")
        XCTAssertFalse(dev.contains("Application acme-envs-prod"))
        XCTAssertEqual(KubeGitOpsSummary.kept(all, scope: .all).count, all.count)
        XCTAssertTrue(names(.namespace("argocd")).contains("Application acme-remote"), "its own namespace keeps it")
        // A managed namespace elsewhere: the destination no longer counts.
        let moved = try object(
            application(status: ["sync": ["status": "Synced"], "resources": [["kind": "Deployment", "name": "web", "namespace": "other"]]]))
        XCTAssertFalse(KubeGitOpsSummary.inScope(moved, .namespace("shop")))
        XCTAssertTrue(KubeGitOpsSummary.inScope(moved, .namespaces(["other", "x"])))
    }

    func testWhatIsServed() {
        func kind(_ group: String, _ resource: String) -> KubeResourceKind {
            KubeResourceKind(group: group, version: "v1", resource: resource, kind: resource, singular: resource, namespaced: true, verbs: ["list", "watch"])
        }
        XCTAssertFalse(KubeGitOpsSummary.served(nil))
        XCTAssertFalse(KubeGitOpsSummary.served(KubeDiscovery(kinds: [kind("", "pods")])))
        XCTAssertTrue(KubeGitOpsSummary.served(KubeDiscovery(kinds: [kind("argoproj.io", "applications")])))
        XCTAssertTrue(KubeGitOpsSummary.served(KubeDiscovery(kinds: [kind("source.toolkit.fluxcd.io", "gitrepositories")])))
        let both = KubeDiscovery(kinds: [kind("argoproj.io", "applications"), kind("argoproj.io", "appprojects"), kind("kustomize.toolkit.fluxcd.io", "kustomizations")])
        XCTAssertEqual(KubeGitOpsSummary.tools(both).argo, 1)
        XCTAssertEqual(KubeGitOpsSummary.tools(both).flux, 1)
        XCTAssertEqual(KubeGitOpsSummary.kinds(both).map(\.fullName), ["applications.argoproj.io", "kustomizations.kustomize.toolkit.fluxcd.io"])
    }

    /// A page of a list: items without a kind given theirs, the next page's token.
    func testAPageOfAList() throws {
        let kind = KubeResourceKind(
            group: "argoproj.io", version: "v1alpha1", resource: "applications", kind: "Application", singular: "application", namespaced: true, verbs: ["list"])
        let page = try JSONSerialization.data(withJSONObject: [
            "metadata": ["continue": "next-token", "remainingItemCount": 3],
            "items": [["metadata": ["name": "a", "namespace": "argocd"], "status": ["sync": ["status": "Synced"], "health": ["status": "Healthy"]]]],
        ])
        let read = try KubeGitOpsSummary.page(page, kind: kind, readAt: now)
        XCTAssertEqual(read.objects.map(\.ref.name), ["a"])
        XCTAssertEqual(read.objects.first?.role, .application)
        XCTAssertEqual(read.next, "next-token")
        XCTAssertEqual(read.remaining, 3)
    }
}
