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
@testable import OvertermNotes
@testable import OvertermSimulator
@testable import OvertermUsage
@testable import OvertermSettingsPage
@testable import OvertermAgents
@testable import OvertermActivity
@testable import OvertermE2E

/// The pure halves of the marks' reads (docs/design/kubernetes/gitops.md,
/// 14.4): when an object is read by a GET — M2 on a moved generation or a
/// row new while shown, never for readiness alone; M1b's settle of what
/// isn't settled, after M2 and only once its first lists are in, what may
/// be a problem first — just synced too —, each the most recently changed
/// first; M3b's CronJobs and `<unknown>` HPAs; 15 s an object, never one
/// being read, 20 a flush, 60 a minute in the context's minute — a place
/// held until a minute after its answer, never freed unanswered, given back
/// unsent — a settled object standing for its row only while it still says
/// the same, the book's ranking, and what a read that wasn't whole may say.
/// Fictional names in the spoke's shape.
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
        var minute = KubeMarkedMinute()
        let ids = (0..<100).map { id("acme-svc-\($0)") }
        for id in ids { refetch.ask(id, .moved) }
        for _ in 0..<3 {
            let taken = refetch.take(now: now, minute: &minute)
            XCTAssertEqual(taken.count, 20)
            for id in taken { minute.answered(id, at: now) }
        }
        XCTAssertEqual(refetch.take(now: now, minute: &minute).count, 0, "the minute's 60")
        XCTAssertEqual(minute.held(at: now), 60)
        XCTAssertEqual(refetch.takenBy[.moved], 60)
        // Hidden and shown again: what waited goes, the minute's count stays.
        refetch.forgetPending()
        XCTAssertTrue(refetch.isEmpty)
        refetch.ask(ids[99], .moved)
        XCTAssertEqual(refetch.take(now: now.addingTimeInterval(30), minute: &minute), [], "the same minute: none")
        // Asked again at once: not before 15 s.
        refetch.ask(ids[0], .moved)
        let later = refetch.take(now: now.addingTimeInterval(61), minute: &minute)
        XCTAssertEqual(Set(later), [ids[0], ids[99]])
        var spaced = KubeMarkedRefetch()
        var its = KubeMarkedMinute()
        spaced.ask(ids[1], .moved)
        XCTAssertEqual(spaced.take(now: now, minute: &its), [ids[1]])
        its.answered(ids[1], at: now)
        spaced.ask(ids[1], .moved)
        XCTAssertEqual(spaced.take(now: now.addingTimeInterval(10), minute: &its), [], "15 s an object")
        XCTAssertEqual(spaced.take(now: now.addingTimeInterval(15), minute: &its), [ids[1]])
    }

    func testTheSettleWaitsBehindMovesNewestChangeFirst() {
        var refetch = KubeMarkedRefetch()
        var minute = KubeMarkedMinute()
        for index in 0..<30 { refetch.ask(id("acme-old-\(index)"), .settle, changed: now.addingTimeInterval(TimeInterval(-3600 - index))) }
        refetch.ask(id("acme-new"), .settle, changed: now.addingTimeInterval(-60))
        refetch.ask(id("acme-moved"), .moved)
        refetch.ask(id("acme-progressing"), .periodic)
        let first = refetch.take(now: now, minute: &minute)
        XCTAssertEqual(first.count, 20)
        XCTAssertEqual(Array(first.prefix(3)), [id("acme-moved"), id("acme-progressing"), id("acme-new")], "M2, the tick, then the newest change")
        XCTAssertEqual(first[3], id("acme-old-0"))
    }

    /// The settle reads what may be a problem first — not Healthy by its
    /// cells, what no cell says, or just synced — then the ready-looking
    /// rest, each the most recently changed by Argo CD first (D7, gitops.md
    /// 14.9.3: on the surveyed spoke ≈1,150 wait, and the minute's 60 go to
    /// them first).
    func testWhatMayBeAProblemIsSettledFirst() {
        var refetch = KubeMarkedRefetch()
        var minute = KubeMarkedMinute()
        for index in 0..<40 { refetch.ask(id("acme-ready-\(index)"), .settle, changed: now.addingTimeInterval(TimeInterval(-60 - index))) }
        refetch.ask(id("acme-stalled"), .settle, changed: now.addingTimeInterval(-86_400), doubtful: true)
        refetch.ask(id("acme-rollout"), .settle, changed: now.addingTimeInterval(-3_600), doubtful: true)
        // Asked again once its row reads ready: the newest row decides.
        refetch.ask(id("acme-recovered"), .settle, changed: now.addingTimeInterval(-7_200), doubtful: true)
        refetch.ask(id("acme-recovered"), .settle, changed: now.addingTimeInterval(-7_200), doubtful: false)
        refetch.ask(id("acme-moved"), .moved)
        let first = refetch.take(now: now, minute: &minute)
        XCTAssertEqual(first.count, 20)
        XCTAssertEqual(Array(first.prefix(3)), [id("acme-moved"), id("acme-rollout"), id("acme-stalled")], "M2, then what may be a problem, the newest change first")
        XCTAssertEqual(first[3], id("acme-ready-0"), "then the ready-looking rest, the newest first")
        XCTAssertFalse(first.contains(id("acme-recovered")), "ready again by its row: among the rest, by when it changed")
        XCTAssertFalse(refetch.doubts.contains(id("acme-stalled")), "taken: no longer waiting")
        refetch.forgetPending()
        XCTAssertTrue(refetch.doubts.isEmpty)
    }

    /// A GET's place in the minute is held until a minute after its answer:
    /// the ten that went out three seconds after they were taken (queued
    /// behind four in flight) free their places a minute after they came
    /// back, never a minute after the take — what the server sees stays at
    /// 60 (D7's leg counted 66 the other way).
    func testAGETsPlaceInTheMinuteCountsFromItsAnswer() {
        var refetch = KubeMarkedRefetch()
        var minute = KubeMarkedMinute()
        let first = (0..<60).map { id("acme-first-\($0)") }
        for id in first { refetch.ask(id, .settle) }
        XCTAssertEqual(refetch.take(now: now, limit: 60, minute: &minute).count, 60)
        for (index, id) in first.enumerated() { minute.answered(id, at: now.addingTimeInterval(index < 50 ? 0.5 : 3)) }
        // An answer never moves a place earlier, and a second answer for one already answered moves nothing.
        minute.answered(first[0], at: now.addingTimeInterval(20))
        for index in 0..<70 { refetch.ask(id("acme-next-\(index)"), .settle) }
        XCTAssertEqual(refetch.take(now: now.addingTimeInterval(60.2), limit: 60, minute: &minute), [], "a minute after the take: no place yet")
        XCTAssertEqual(refetch.take(now: now.addingTimeInterval(60.6), limit: 60, minute: &minute).count, 50, "a minute after the fifty came back")
        XCTAssertEqual(minute.held(at: now.addingTimeInterval(61)), 60)
        XCTAssertEqual(refetch.take(now: now.addingTimeInterval(62), limit: 60, minute: &minute), [])
        XCTAssertEqual(refetch.take(now: now.addingTimeInterval(63), limit: 60, minute: &minute).count, 10, "the last ten's a minute after theirs")
    }

    /// A slow server: a GET's place is never freed while it is unanswered —
    /// however long — so no backlog builds behind four in flight to go out
    /// at once when the server speeds up; each frees a minute after its
    /// answer; one taken and never sent (hidden while it waited) is given
    /// back at once (D7's fix pass).
    func testAPlaceIsNeverFreedUnanswered() {
        var refetch = KubeMarkedRefetch()
        var minute = KubeMarkedMinute()
        let first = (0..<60).map { id("acme-slow-\($0)") }
        for id in first { refetch.ask(id, .settle) }
        XCTAssertEqual(refetch.take(now: now, limit: 60, minute: &minute).count, 60)
        for index in 0..<100 { refetch.ask(id("acme-later-\(index)"), .settle) }
        XCTAssertEqual(refetch.take(now: now.addingTimeInterval(120), limit: 60, minute: &minute), [], "two minutes on, none answered: no place")
        XCTAssertEqual(refetch.take(now: now.addingTimeInterval(3_600), limit: 60, minute: &minute), [], "nor an hour on")
        // Four answered at two minutes: their places free a minute after.
        for id in first.prefix(4) { minute.answered(id, at: now.addingTimeInterval(120)) }
        XCTAssertEqual(refetch.take(now: now.addingTimeInterval(179), limit: 60, minute: &minute), [], "answered at 120 s, held to 180 s")
        XCTAssertEqual(refetch.take(now: now.addingTimeInterval(180), limit: 60, minute: &minute).count, 4)
        // Never sent: given back at once.
        for id in first.suffix(6) { minute.unsent(id) }
        XCTAssertEqual(refetch.take(now: now.addingTimeInterval(180), limit: 60, minute: &minute).count, 6)
        XCTAssertEqual(minute.held(at: now.addingTimeInterval(10_000)), 60, "every place still held: none answered")
        // An answer stamped before its take frees nothing earlier than a minute after the take.
        var early = KubeMarkedMinute()
        early.took(id("acme-early"), at: now.addingTimeInterval(10))
        early.answered(id("acme-early"), at: now)
        XCTAssertEqual(early.held(at: now.addingTimeInterval(69)), 1)
        XCTAssertEqual(early.held(at: now.addingTimeInterval(70)), 0)
        // Spent places forgotten, and objects asked a minute ago: an empty minute.
        var spent = KubeMarkedMinute()
        spent.took(id("acme-once"), at: now)
        spent.answered(id("acme-once"), at: now)
        spent.prune(now: now.addingTimeInterval(60))
        XCTAssertTrue(spent.isEmpty)
    }

    /// What is being read (taken, waiting its turn or in flight) is never
    /// taken twice, and the settle waits until its first lists are in
    /// (`through`): M2's moves and the tick's go first meanwhile.
    func testWhatIsBeingReadAndTheSettleBeforeItsListsWait() {
        var refetch = KubeMarkedRefetch()
        var minute = KubeMarkedMinute()
        refetch.ask(id("acme-moved"), .moved)
        refetch.ask(id("acme-flight"), .moved)
        refetch.ask(id("acme-progressing"), .periodic)
        refetch.ask(id("acme-settle"), .settle, doubtful: true)
        let early = refetch.take(now: now, busy: [id("acme-flight")], through: .periodic, minute: &minute)
        XCTAssertEqual(Set(early), [id("acme-moved"), id("acme-progressing")], "nothing of the settle's before its lists; nothing being read")
        XCTAssertEqual(refetch.pending[id("acme-flight")], .moved, "asked again while it is read: waits")
        XCTAssertEqual(refetch.pending[id("acme-settle")], .settle)
        let later = refetch.take(now: now, through: .settle, minute: &minute)
        XCTAssertEqual(Set(later), [id("acme-flight"), id("acme-settle")])
        XCTAssertEqual(refetch.takenBy, [.moved: 2, .periodic: 1, .settle: 1])
    }

    /// What may be a problem, by its row: in progress by its cells, what no
    /// cell says, or a workload Argo CD changed in the last hour (a single
    /// replica stuck behind its old pod reads `1/1`) — never one ready by
    /// its cells and changed long ago, nor one scaled to 0 long ago.
    func testARowNotHealthyByItsCellsOrSayingNothingOrJustSyncedIsDoubtful() {
        let old = now.addingTimeInterval(-86_400)
        func doubtful(_ row: KubeRow, _ kind: KubeMarkedKind = .deployment, columns: [KubeColumn]? = nil, changed: Date? = nil) -> Bool {
            KubeMarkedRefetch.doubtful(row, kind: kind, columns: columns ?? self.columns, changed: changed ?? old, now: now)
        }
        XCTAssertFalse(doubtful(row()), "2/2 ready")
        XCTAssertTrue(doubtful(row(ready: "1/2", updated: "1", available: "1")), "1/2 updated")
        XCTAssertTrue(doubtful(row(ready: "2/3", updated: "3", available: "2")), "2/3 available")
        XCTAssertFalse(doubtful(row(ready: "0/0", updated: "0", available: "0")), "scaled to 0: Healthy by its cells")
        XCTAssertTrue(doubtful(row(), .rollout), "a Rollout's phase is in no cell")
        XCTAssertTrue(doubtful(row(), .cronJob), "nor a CronJob's last run")
        let hpaColumns = ["Name", "Targets"].map { KubeColumn(name: $0, format: $0 == "Name" ? "name" : "") }
        func hpa(_ targets: String) -> KubeRow { KubeRow(id: KubeRowID(namespace: "team-3", name: "acme-checkout"), cells: [.text("acme-checkout"), .text(targets)]) }
        XCTAssertTrue(doubtful(hpa("cpu: <unknown>/70%"), .horizontalPodAutoscaler, columns: hpaColumns), "an <unknown> target")
        XCTAssertFalse(doubtful(hpa("cpu: 40%/70%"), .horizontalPodAutoscaler, columns: hpaColumns))
        // Just synced: a single replica's `1/1` may be its old pod serving.
        XCTAssertTrue(doubtful(row(ready: "1/1", updated: "1", available: "1"), changed: now.addingTimeInterval(-1_200)), "changed by Argo CD 20 min ago")
        XCTAssertFalse(doubtful(row(ready: "1/1", updated: "1", available: "1"), changed: now.addingTimeInterval(-KubeMarkedRefetch.recentlyChanged)), "an hour ago")
        XCTAssertTrue(doubtful(row(), .statefulSet, columns: ["Name", "Ready"].map { KubeColumn(name: $0, format: $0 == "Name" ? "name" : "") }, changed: now.addingTimeInterval(-60)))
        XCTAssertFalse(doubtful(hpa("cpu: 40%/70%"), .horizontalPodAutoscaler, columns: hpaColumns, changed: now.addingTimeInterval(-60)), "an HPA's cells say what its object would")
        XCTAssertFalse(
            KubeMarkedRefetch.doubtful(row(), kind: .deployment, columns: columns, changed: nil, now: now), "when it changed unknown: by its cells alone")
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

    /// The section's rows are the book's, made off the main thread with the
    /// apps (14.4.6): every app's at first, then only the changed apps',
    /// the rest kept as they were — in the section's own order, so the main
    /// thread only lays them among the rest.
    func testTheBookMakesOnlyTheChangedAppsRows() {
        var book = KubeMarkedBook()
        let changes = (0..<50).map { index -> KubeMarkedBook.Change in
            let name = "acme-svc-\(index)"
            let notReady = index % 10 == 3
            return .init(id: id(name), source: .row(row(name, ready: notReady ? "1/2" : "2/2", available: notReady ? "1" : "2"), columns: columns))
        }
        XCTAssertTrue(book.apply(changes, removed: [], now: now))
        XCTAssertEqual(book.rowsMade, 50)
        XCTAssertEqual(book.shownRows.map(\.id), book.shownRows.sorted(by: KubeGitOpsSection.ordered).map(\.id), "the section's order")
        XCTAssertEqual(Set(book.shownRows.compactMap(\.marked?.key)), Set(book.ranked.map(\.app.key)))
        XCTAssertEqual(book.shownRows.first?.state, .progressing)
        XCTAssertEqual(
            KubeMarkedSection.derived(rows: book.shownRows, mode: .only(.notServed), applications: .notYetListed).shown,
            KubeMarkedSection.derived(book.ranked, mode: .only(.notServed), applications: .notYetListed).shown.sorted(by: KubeGitOpsSection.ordered),
            "the same rows as made on the spot")
        // One app's row moves: one row made again, every other kept as it was.
        let later = now.addingTimeInterval(30)
        XCTAssertTrue(book.apply([.init(id: id("acme-svc-7"), source: .row(row("acme-svc-7", ready: "1/2", available: "1"), columns: columns))], removed: [], now: later))
        XCTAssertEqual(book.rowsMade, 51)
        let moved = book.rows[.init(installation: "", instance: "prod-team-3-acme-svc-7-service")]
        XCTAssertEqual(moved?.state, .progressing)
        XCTAssertEqual(moved?.since, later, "since it was first read not ready, for the Age column")
        XCTAssertEqual(moved?.marked?.sinceSaid, KubeMarkedHealth.sinceFirstRead)
        XCTAssertFalse(moved?.why.contains(" for ") ?? true, "no duration baked into the why: \(moved?.why ?? "")")
        // The same again: nothing shown changed, nothing made.
        XCTAssertFalse(book.apply([.init(id: id("acme-svc-7"), source: .row(row("acme-svc-7", ready: "1/2", available: "1"), columns: columns))], removed: [], now: later))
        XCTAssertEqual(book.rowsMade, 51)
        XCTAssertEqual(book.rows[.init(installation: "", instance: "prod-team-3-acme-svc-7-service")]?.since, later, "still when it was first read not ready")
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
