import XCTest

@testable import Overterm

/// The pure halves of the marks' reads (docs/design/kubernetes/gitops.md,
/// 14.4): when M2 reads an object again — a moved generation, not-ready
/// cells, a last unhealthy state, never a ready row that stays ready; 15 s
/// an object, 20 a flush, 60 a minute — what a page of whole objects
/// keeps (the allow-list, the sentinel nowhere), a settled object
/// standing for its row only while it still says the same, the book's
/// ranking, and what a read that wasn't whole may say. Fictional names in
/// the spoke's shape.
final class KubeMarkedReadsTests: XCTestCase {
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    let columns = ["Name", "Ready", "Up-to-date", "Available", "Images"].map { KubeColumn(name: $0, format: $0 == "Name" ? "name" : "") }

    private func row(_ name: String = "acme-checkout", ready: String = "2/2", updated: String = "2", available: String = "2", generation: Int? = 4) -> KubeRow {
        var row = KubeRow(
            id: KubeRowID(namespace: "team-3", name: name), cells: [.text(name), .text(ready), .text(updated), .text(available), .text("registry.acme.example/x:1")])
        var marks = KubeMarkWire()
        marks.tracking = .own(KubeTrackingID.parse("prod-team-3-\(name)-service:apps/Deployment:team-3/\(name)")!)
        marks.generation = generation
        row.marks = marks
        return row
    }

    private func id(_ name: String) -> KubeMarkedMember.ID { KubeMarkedMember.ID(kind: .deployment, namespace: "team-3", name: name) }

    private func settled(generation: Int = 4, ready: Int = 2, at: Date? = nil) -> KubeMarkedSettled {
        let wire = try! KubeMarkedWorkloadWire.decode(
            JSONSerialization.data(withJSONObject: [
                "apiVersion": "apps/v1", "kind": "Deployment", "metadata": ["name": "acme-checkout", "namespace": "team-3", "generation": generation],
                "spec": ["replicas": 2],
                "status": ["observedGeneration": generation, "replicas": 2, "updatedReplicas": 2, "readyReplicas": ready, "availableReplicas": ready],
            ]))
        return KubeMarkedSettled(wire, at: at ?? now)
    }

    // MARK: M2's reasons

    func testAMovedGenerationNotReadyCellsOrALastUnhealthyStateAreReadAgain() {
        let reason = { (old: KubeRow?, new: KubeRow, settled: KubeMarkedSettled?) in
            KubeMarkedRefetch.reason(old: old, new: new, kind: .deployment, columns: self.columns, settled: settled, now: self.now)
        }
        XCTAssertNil(reason(row(), row(), settled()), "nothing moved")
        XCTAssertNil(reason(row(), row(ready: "3/3", updated: "3", available: "3"), settled()), "a ready row that stays ready")
        XCTAssertEqual(reason(row(), row(generation: 5), settled()), .moved, "a spec change")
        XCTAssertEqual(reason(row(), row(ready: "1/2", available: "1"), settled()), .problem, "not ready now")
        XCTAssertEqual(reason(row(), row(ready: "3/3", updated: "3", available: "3"), settled(ready: 1)), .problem, "last settled unhealthy")
        XCTAssertEqual(reason(nil, row(), nil), .moved, "new")
    }

    func testFifteenSecondsAnObjectTwentyAFlushSixtyAMinute() {
        var refetch = KubeMarkedRefetch()
        let ids = (0..<100).map { id("acme-svc-\($0)") }
        for id in ids { refetch.ask(id, .problem) }
        XCTAssertEqual(refetch.take(now: now).count, 20)
        XCTAssertEqual(refetch.take(now: now).count, 20)
        XCTAssertEqual(refetch.take(now: now).count, 20)
        XCTAssertEqual(refetch.take(now: now).count, 0, "the minute's 60")
        XCTAssertEqual(refetch.takenInLastMinute(now: now), 60)
        // Asked again at once: not before 15 s.
        refetch.ask(ids[0], .problem)
        let later = refetch.take(now: now.addingTimeInterval(61))
        XCTAssertEqual(later.count, 20)
        XCTAssertTrue(later.contains(ids[0]), "problems first, and it is due")
        var spaced = KubeMarkedRefetch()
        spaced.ask(ids[1], .moved)
        XCTAssertEqual(spaced.take(now: now), [ids[1]])
        spaced.ask(ids[1], .moved)
        XCTAssertEqual(spaced.take(now: now.addingTimeInterval(10)), [], "15 s an object")
        XCTAssertEqual(spaced.take(now: now.addingTimeInterval(15)), [ids[1]])
    }

    // MARK: Settled

    func testASettledObjectStandsForItsRowOnlyWhileItSaysTheSame() {
        let read = settled(at: now)
        XCTAssertTrue(read.describes(row(), kind: .deployment, columns: columns, changedAt: nil, now: now))
        XCTAssertFalse(read.describes(row(generation: 5), kind: .deployment, columns: columns, changedAt: nil, now: now), "another generation")
        XCTAssertFalse(
            read.describes(row(ready: "1/2", available: "1"), kind: .deployment, columns: columns, changedAt: now.addingTimeInterval(5), now: now),
            "not ready since it was read: the row's")
        XCTAssertTrue(read.describes(row(ready: "1/2", available: "1"), kind: .deployment, columns: columns, changedAt: now.addingTimeInterval(-5), now: now))
    }

    func testAPageOfWholeObjectsKeepsTheAllowListOnly() throws {
        let sentinel = FakeKubeAPI.gitOpsSentinel
        let page: [String: Any] = [
            "kind": "DeploymentList", "apiVersion": "apps/v1", "metadata": ["continue": "next-page", "remainingItemCount": 12],
            "items": [
                [
                    "metadata": [
                        "name": "acme-pay", "namespace": "team-1", "generation": 3,
                        "annotations": ["kubectl.kubernetes.io/last-applied-configuration": sentinel, "acme.example/note": sentinel],
                    ],
                    "spec": [
                        "replicas": 1,
                        "template": ["spec": ["containers": [["name": "app", "image": "registry.acme.example/pay:4.1", "env": [["name": "TOKEN", "value": sentinel]], "args": [sentinel]]]]],
                    ],
                    "status": ["observedGeneration": 3, "replicas": 2, "updatedReplicas": 1, "availableReplicas": 1],
                ]
            ],
        ]
        let data = try JSONSerialization.data(withJSONObject: page)
        let read = try KubeMarkedWorkloadWire.page(data, kind: KubeGitOpsSession.deployments)
        XCTAssertEqual(read.next, "next-page")
        XCTAssertEqual(read.remaining, 12)
        XCTAssertEqual(read.items.first?.kind, "Deployment", "a list's items carry no kind: the kind listed")
        XCTAssertEqual(read.items.first?.images, ["registry.acme.example/pay:4.1"])
        XCTAssertFalse(String(describing: read.items).contains(sentinel), "nothing outside the allow-list")
        XCTAssertEqual(KubeMarkedHealth.object(read.items[0])?.status, .progressing, "its old pod still serves")
    }

    func testAPageOfCronJobsKeepsTheirMarksAndHealth() throws {
        let sentinel = FakeKubeAPI.gitOpsSentinel
        let cronJobs = KubeResourceKind(group: "batch", version: "v1", resource: "cronjobs", kind: "CronJob", singular: "cronjob", namespaced: true, verbs: ["list"])
        let page: [String: Any] = [
            "items": [
                [
                    "metadata": [
                        "name": "acme-reindex", "namespace": "team-8",
                        "annotations": [
                            "argocd.argoproj.io/tracking-id": "prod-team-8-acme-reindex-service:batch/CronJob:team-8/acme-reindex",
                            "kubectl.kubernetes.io/last-applied-configuration": sentinel,
                        ],
                    ],
                    "spec": ["jobTemplate": ["spec": ["template": ["spec": ["containers": [["name": "r", "image": "registry.acme.example/r:2", "env": [["name": "K", "value": sentinel]]]]]]]]],
                    "status": ["lastScheduleTime": "2026-11-14T09:00:00Z", "lastSuccessfulTime": "2026-11-14T07:00:00Z"],
                ]
            ]
        ]
        let read = try KubeMarkedMember.objects(JSONSerialization.data(withJSONObject: page), kind: cronJobs)
        XCTAssertEqual(read.items.count, 1)
        let member = read.items[0]
        XCTAssertEqual(member.id, KubeMarkedMember.ID(kind: .cronJob, namespace: "team-8", name: "acme-reindex"))
        guard case .own(let tracking) = member.marks.tracking else { return XCTFail("its own mark") }
        XCTAssertEqual(tracking.instance, "prod-team-8-acme-reindex-service")
        XCTAssertEqual(member.health?.status, .degraded)
        XCTAssertFalse(String(describing: member).contains(sentinel))
    }

    // MARK: The book

    func testTheBookRanksProblemsFirstAndMakesOnlyWhatChanged() {
        var book = KubeMarkedBook()
        let changes = (0..<5).map { index -> KubeMarkedBook.Change in
            let name = "acme-svc-\(index)"
            let ready = index == 3 ? "1/2" : "2/2"
            return .init(id: id(name), source: .row(row(name, ready: ready, available: index == 3 ? "1" : "2"), columns: columns))
        }
        XCTAssertTrue(book.apply(changes, removed: [], now: now))
        XCTAssertEqual(book.ranked.count, 5)
        XCTAssertEqual(book.ranked.first?.app.key.instance, "prod-team-3-acme-svc-3-service")
        XCTAssertEqual(book.ranked.first?.health.state, .progressing)
        XCTAssertNotNil(book.notReadySince[id("acme-svc-3")])
        let made = book.apps.membersMade
        XCTAssertFalse(book.apply([changes[0]], removed: [], now: now), "the same row: nothing shown changed")
        XCTAssertEqual(book.apps.membersMade - made, 1, "one app made again")
        XCTAssertTrue(book.apply([], removed: [id("acme-svc-3")], now: now))
        XCTAssertEqual(book.ranked.count, 4)
        XCTAssertNil(book.notReadySince[id("acme-svc-3")])
    }

    func testASettledObjectSaysWhatItsCellsCant() {
        var book = KubeMarkedBook()
        let stuck = try! KubeMarkedWorkloadWire.decode(
            JSONSerialization.data(withJSONObject: [
                "apiVersion": "apps/v1", "kind": "Deployment", "metadata": ["name": "acme-pay", "namespace": "team-3", "generation": 4], "spec": ["replicas": 1],
                "status": ["observedGeneration": 4, "replicas": 2, "updatedReplicas": 1, "readyReplicas": 1, "availableReplicas": 1],
            ]))
        let cells = row("acme-pay", ready: "1/1", updated: "1", available: "1")
        book.apply([.init(id: id("acme-pay"), source: .row(cells, columns: columns))], removed: [], now: now)
        XCTAssertEqual(book.ranked.first?.health.state, .ready)
        XCTAssertEqual(book.ranked.first?.health.fromRows, true, "ready by its row only")
        book.apply([.init(id: id("acme-pay"), source: .row(cells, columns: columns), settled: KubeMarkedSettled(stuck, at: now))], removed: [], now: now)
        XCTAssertEqual(book.ranked.first?.health.state, .progressing)
        XCTAssertEqual(book.ranked.first?.health.fromRows, false)
    }

    // MARK: What a read may say

    func testOnlyAWholeReadSaysNoMarks() {
        var reading = KubeMarkedReading()
        reading.kinds = ["Deployments", "StatefulSets", "DaemonSets"]
        XCTAssertTrue(reading.isReading)
        XCTAssertNil(reading.count(0), "no count while the first rows come")
        XCTAssertEqual(reading.empty(context: "fake-prod", scope: .all, served: false), "Reading the marks on Deployments, StatefulSets and DaemonSets…")
        reading.listed = ["Deployments", "StatefulSets", "DaemonSets"]
        XCTAssertTrue(reading.isWhole)
        XCTAssertEqual(
            reading.empty(context: "fake-prod", scope: .all, served: false),
            "No Argo CD Application is served by fake-prod, and no Deployment, StatefulSet or DaemonSet in all namespaces carries Argo CD's marks.")
        XCTAssertEqual(reading.count(894), "894 apps")
        reading.refused["Deployments"] = ["team-a", "team-b", "team-c"]
        XCTAssertFalse(reading.isWhole)
        XCTAssertEqual(
            reading.empty(context: "fake-prod", scope: .all, served: false),
            "No Argo CD marks found in what could be read: Deployments refused in 3 namespaces (team-a, team-b, team-c)")
        XCTAssertEqual(reading.count(12), "At least 12 apps, from what could be read: Deployments refused in 3 namespaces (team-a, team-b, team-c)")
        reading.refused = [:]
        reading.rowCuts["Deployments"] = "Deployments: the list stopped at 5,000; the rest not read"
        XCTAssertEqual(reading.empty(context: "fake-prod", scope: .all, served: false).contains("stopped at 5,000"), true)
    }
}
