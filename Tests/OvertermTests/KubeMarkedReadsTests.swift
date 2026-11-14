import XCTest

@testable import Overterm

/// The pure halves of the marks' reads (docs/design/kubernetes/gitops.md,
/// 14.4): when an object is read by a GET — M2 on a moved generation or a
/// row new while shown, never for readiness alone; M1b's settle of what
/// isn't settled, the most recently changed first, after M2; M3b's
/// CronJobs and `<unknown>` HPAs; 15 s an object, 20 a flush, 60 a
/// minute, kept across a hide — a settled object standing for its row
/// only while it still says the same, the book's ranking, and what a read
/// that wasn't whole may say. Fictional names in the spoke's shape.
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

    // MARK: When an object is read

    func testAMovedGenerationIsReadNeverReadinessAlone() {
        let reason = { (old: KubeRow?, new: KubeRow, settled: KubeMarkedSettled?, listing: Bool) in
            KubeMarkedRefetch.reason(old: old, new: new, kind: .deployment, columns: self.columns, settled: settled, listing: listing, now: self.now)
        }
        XCTAssertNil(reason(row(), row(), settled(), false), "nothing moved")
        XCTAssertNil(reason(row(), row(ready: "3/3", updated: "3", available: "3"), settled(), false), "a ready row that stays ready")
        XCTAssertEqual(reason(row(), row(generation: 5), settled(), false), .moved, "a spec change")
        XCTAssertNil(reason(row(), row(ready: "1/2", available: "1"), settled(), false), "not ready, its generation the same: its cells say it")
        XCTAssertNil(reason(row(), row(ready: "3/3", updated: "3", available: "3"), settled(ready: 1), false), "last settled unhealthy: the tick's")
        XCTAssertEqual(reason(nil, row(), nil, false), .moved, "new while shown")
        XCTAssertEqual(reason(nil, row(), nil, true), .settle, "first listed, not settled: the settle's")
        XCTAssertNil(reason(nil, row(), settled(), true), "settled at its generation: not again on a re-show")
        XCTAssertEqual(reason(nil, row(generation: 5), settled(), true), .moved, "moved since it was settled")
        // A Rollout's counts moving with its generation the same: nothing.
        XCTAssertNil(
            KubeMarkedRefetch.reason(
                old: row(ready: "3"), new: row(ready: "1"), kind: .rollout, columns: columns, settled: settled(), listing: false, now: now))
    }

    func testCronJobsAndUnknownHPAsAreReadOnceAndWhenTheirRowMoves() {
        let hpaColumns = ["Name", "Reference", "Targets"].map { KubeColumn(name: $0, format: $0 == "Name" ? "name" : "") }
        func hpa(_ targets: String) -> KubeRow {
            var row = KubeRow(id: KubeRowID(namespace: "team-5", name: "acme-search"), cells: [.text("acme-search"), .text("Deployment/acme-search"), .text(targets)])
            row.marks = KubeMarkWire()
            return row
        }
        func reason(_ old: KubeRow?, _ new: KubeRow, _ settled: KubeMarkedSettled?, kind: KubeMarkedKind = .horizontalPodAutoscaler) -> KubeMarkedRefetch.Priority? {
            KubeMarkedRefetch.reason(old: old, new: new, kind: kind, columns: hpaColumns, settled: settled, listing: old == nil, now: now)
        }
        XCTAssertEqual(reason(nil, hpa("cpu: <unknown>/70%"), nil), .settle)
        XCTAssertNil(reason(nil, hpa("cpu: 40%/70%"), nil), "every target read: Healthy from its row")
        XCTAssertNil(reason(hpa("cpu: <unknown>/70%"), hpa("cpu: <unknown>/70%"), settled()))
        XCTAssertEqual(reason(hpa("cpu: <unknown>/70%"), hpa("cpu: <unknown>/80%"), settled()), .settle, "its row moved")
        XCTAssertEqual(reason(nil, hpa(""), nil, kind: .cronJob), .settle, "a CronJob's last run is in no cell")
        XCTAssertNil(reason(hpa("a"), hpa("a"), settled(), kind: .cronJob))
        XCTAssertNil(reason(nil, hpa(""), nil, kind: .service), "a Service's cells say it")
    }

    func testFifteenSecondsAnObjectTwentyAFlushSixtyAMinute() {
        var refetch = KubeMarkedRefetch()
        let ids = (0..<100).map { id("acme-svc-\($0)") }
        for id in ids { refetch.ask(id, .moved) }
        XCTAssertEqual(refetch.take(now: now).count, 20)
        XCTAssertEqual(refetch.take(now: now).count, 20)
        XCTAssertEqual(refetch.take(now: now).count, 20)
        XCTAssertEqual(refetch.take(now: now).count, 0, "the minute's 60")
        XCTAssertEqual(refetch.takenInLastMinute(now: now), 60)
        // Hidden and shown again: what waited goes, the minute's count stays.
        refetch.forgetPending()
        XCTAssertTrue(refetch.isEmpty)
        refetch.ask(ids[99], .moved)
        XCTAssertEqual(refetch.take(now: now.addingTimeInterval(30)), [], "the same minute: none")
        // Asked again at once: not before 15 s.
        refetch.ask(ids[0], .moved)
        let later = refetch.take(now: now.addingTimeInterval(61))
        XCTAssertEqual(Set(later), [ids[0], ids[99]])
        var spaced = KubeMarkedRefetch()
        spaced.ask(ids[1], .moved)
        XCTAssertEqual(spaced.take(now: now), [ids[1]])
        spaced.ask(ids[1], .moved)
        XCTAssertEqual(spaced.take(now: now.addingTimeInterval(10)), [], "15 s an object")
        XCTAssertEqual(spaced.take(now: now.addingTimeInterval(15)), [ids[1]])
    }

    func testTheSettleWaitsBehindMovesNewestChangeFirst() {
        var refetch = KubeMarkedRefetch()
        for index in 0..<30 { refetch.ask(id("acme-old-\(index)"), .settle, changed: now.addingTimeInterval(TimeInterval(-3600 - index))) }
        refetch.ask(id("acme-new"), .settle, changed: now.addingTimeInterval(-60))
        refetch.ask(id("acme-moved"), .moved)
        refetch.ask(id("acme-progressing"), .periodic)
        let first = refetch.take(now: now)
        XCTAssertEqual(first.count, 20)
        XCTAssertEqual(Array(first.prefix(3)), [id("acme-moved"), id("acme-progressing"), id("acme-new")], "M2, the tick, then the newest change")
        XCTAssertEqual(first[3], id("acme-old-0"))
    }

    // MARK: Settled

    func testASettledHPAStandsOnlyWhileATargetReadsUnknown() {
        let hpaColumns = ["Name", "Targets"].map { KubeColumn(name: $0, format: $0 == "Name" ? "name" : "") }
        func hpa(_ targets: String) -> KubeRow {
            var row = KubeRow(id: KubeRowID(namespace: "team-5", name: "acme-search"), cells: [.text("acme-search"), .text(targets)])
            row.marks = KubeMarkWire()
            return row
        }
        let read = settled()
        XCTAssertTrue(read.describes(hpa("cpu: <unknown>/70%"), kind: .horizontalPodAutoscaler, columns: hpaColumns, changedAt: nil, now: now))
        XCTAssertFalse(read.describes(hpa("cpu: 40%/70%"), kind: .horizontalPodAutoscaler, columns: hpaColumns, changedAt: nil, now: now))
    }

    func testASettledObjectStandsForItsRowOnlyWhileItSaysTheSame() {
        let read = settled(at: now)
        XCTAssertTrue(read.describes(row(), kind: .deployment, columns: columns, changedAt: nil, now: now))
        XCTAssertFalse(read.describes(row(generation: 5), kind: .deployment, columns: columns, changedAt: nil, now: now), "another generation")
        XCTAssertFalse(
            read.describes(row(ready: "1/2", available: "1"), kind: .deployment, columns: columns, changedAt: now.addingTimeInterval(5), now: now),
            "not ready since it was read: the row's")
        XCTAssertTrue(read.describes(row(ready: "1/2", available: "1"), kind: .deployment, columns: columns, changedAt: now.addingTimeInterval(-5), now: now))
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
        var rollouts = reading
        rollouts.kinds.append("Rollouts")
        rollouts.listed.insert("Rollouts")
        XCTAssertEqual(
            rollouts.empty(context: "fake-dev", scope: .all, served: true),
            "No Argo CD Application deploys here, and no Deployment, StatefulSet, DaemonSet or Rollout in all namespaces carries Argo CD's marks.",
            "the Rollouts read too")
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
