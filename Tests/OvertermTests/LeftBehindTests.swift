import Darwin
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
@testable import OvertermNotes

/// Left Behind's signs (docs/design/activity/analysis.md, 6.9; 6.5 rules 8
/// and 11) over a fake Mac: a closed pane's tag, an agent run's window from
/// the census, an earlier Overterm's marker and argv sign, a test run's, a
/// dead group leader; what is never Left Behind; Keep; the tab's note.
/// Every name and path is invented.
final class LeftBehindTests: XCTestCase {
    private let kernel = FakeActivityKernel(uid: 501)
    private let app: pid_t = 1000
    private let tab = UUID()
    private let pty: dev_t = 0x1000_0003
    private let checkout = "/Users/fake/src/acme-shop"

    @discardableResult
    private func add(
        _ pid: pid_t, parent: pid_t, uid: uid_t = 501, name: String, path: String? = nil, words: [String]? = nil, environment: [String] = [],
        terminal: dev_t? = nil, group: pid_t? = nil, ignoresHangup: Bool = false, platform: Bool = false, port: UInt16? = nil
    ) -> ActivityProcessID {
        let start = UInt64(pid) * 1_000
        let record = FakeActivityKernel.record(
            pid: pid, start: start, parent: parent, uid: uid, realUID: uid == 0 && name == "login" ? 501 : nil, group: group, terminal: terminal,
            ignoredSignals: ignoresHangup ? UInt32(1) << UInt32(SIGHUP - 1) : 0, name: name)
        var process = FakeActivityKernel.Process(record: record)
        process.name = name
        process.path = path ?? "/opt/acme/bin/\(name)"
        process.codeSigning = ActivityCodeSigning(flags: ActivityCodeSigning.valid | (platform ? ActivityCodeSigning.platformBinary : 0))
        process.usage = FakeActivityKernel.usage(footprint: 4 << 20)
        process.arguments = FakeActivityKernel.arguments(executable: process.path ?? name, words ?? [name], environment: environment)
        if let port {
            process.descriptors = [FakeActivityKernel.descriptor(3)]
            process.sockets = [3: FakeActivityKernel.tcp(local: "127.0.0.1", port: port, handle: UInt64(pid))]
        }
        kernel.add(process)
        return ActivityProcessID(pid: pid, start: start)
    }

    /// launchd, the app, one pane with its login and shell.
    private func base() -> ActivityContext {
        add(1, parent: 0, uid: 0, name: "launchd", path: "/sbin/launchd", platform: true)
        add(app, parent: 1, name: "Overterm", path: "/Applications/Overterm.app/Contents/MacOS/Overterm")
        let login = add(1100, parent: app, uid: 0, name: "login", path: "/usr/bin/login", terminal: pty, group: 1100, platform: true)
        add(1101, parent: 1100, name: "zsh", path: "/bin/zsh", terminal: pty, group: 1101, platform: true)
        var context = ActivityContext(panes: [ActivityContext.Pane(tag: "pane-a", tab: tab, login: login, terminal: pty)], appPID: app)
        context.run = "release.\(app).\(UInt64(app) * 1_000)"
        return context
    }

    private func snapshot(_ context: ActivityContext) throws -> ActivitySnapshot {
        try XCTUnwrap(ActivitySampler(kernel: kernel).tickNow(ActivityDemand(.full), context: context))
    }

    private func owners(_ snapshot: ActivitySnapshot, _ context: ActivityContext) -> ActivityAttribution {
        ActivityAttribution.of(
            snapshot, context: context,
            inputs: ActivityAttribution.Inputs(tabs: [tab: ActivityTabFacts(id: tab, title: "web", checkout: checkout)], checkouts: [checkout]))
    }

    private func retired(_ tag: String, agent: Agent? = .claude) -> ActivityContext.RetiredPane {
        ActivityContext.RetiredPane(
            pane: ActivityContext.Pane(tag: tag, tab: UUID(), title: "api", checkout: checkout, agent: agent),
            closed: Date(timeIntervalSince1970: 1_700_000_000))
    }

    // MARK: Rule 8: an agent's run, its window from the census

    func testWhatAnEndedAgentRunLeftIsLeftBehindWithItsReason() throws {
        var context = base()
        // Before the agent: a job the person nohup'd themselves.
        let before = add(1050, parent: 1, name: "acme-worker", environment: ["OVERTERM_TAB_ID=pane-a"])
        add(1103, parent: 1101, name: "claude", words: ["claude"], terminal: pty, group: 1103)
        var runs = ActivityAgentRuns()
        XCTAssertTrue(runs.observe(try snapshot(context)).isEmpty, "a run begins: nothing has ended")
        XCTAssertEqual(runs.running["pane-a"]?.identity.pid, 1103)
        XCTAssertEqual(runs.running["pane-a"]?.foreground, true)
        // The agent's tool started a server that left its terminal; the agent exits.
        let server = add(1700, parent: 1, name: "acme-server", environment: ["OVERTERM_TAB_ID=pane-a"], port: 5173)
        let child = add(1701, parent: 1700, name: "acme-child", environment: ["OVERTERM_TAB_ID=pane-a"])
        kernel.remove(1103)
        let after = try snapshot(context)
        let ended = runs.observe(after)
        XCTAssertEqual(ended.map(\.identity.pid), [1103], "the census found it gone")
        XCTAssertTrue(runs.running.isEmpty)
        context.agentRuns = runs.ended
        let attribution = owners(after, context)
        let left = try XCTUnwrap(attribution[server])
        XCTAssertEqual(left.place, .leftBehind)
        XCTAssertEqual(left.rule, 8)
        XCTAssertEqual(left.certainty, .certain, "the agent was the pane's only foreground job")
        XCTAssertTrue(left.reason?.hasPrefix("left by Claude in “web”, which exited at ") == true, left.reason ?? "")
        XCTAssertEqual(attribution[child]?.place, .leftBehind, "what it started is left with it")
        let earlier = try XCTUnwrap(attribution[before])
        XCTAssertEqual(earlier.place, .pane("pane-a"), "started before the agent: the person's, rule 9")
        XCTAssertEqual(earlier.rule, 9)
        // The tab's note.
        let items = LeftBehind.left(by: ended[0], in: after, checkouts: [checkout], kept: [])
        XCTAssertEqual(items.map(\.identity), [server, child])
        XCTAssertEqual(items.first?.ports, [5173])
        XCTAssertEqual(LeftBehind.note(.claude, left: items), "Claude finished — left acme-server :5173 and 1 more running")
        XCTAssertEqual(LeftBehind.left(by: ended[0], in: after, checkouts: [checkout], kept: [server, child]), [], "kept ones are no news")
    }

    func testAnAgentThatSharedItsPaneIsOnlyProbably() throws {
        var context = base()
        // The agent in the background: the person's own jobs could start too.
        add(1103, parent: 1101, name: "codex", words: ["codex"], terminal: pty, group: 1103)
        kernel.update(1103) { process in
            process.record = ActivityProcess(
                identity: process.record.identity, parentPID: 1101, group: 1103, terminal: self.pty, terminalGroup: 1101, effectiveUID: 501,
                realUID: 501, savedUID: 501, status: SRUN, flags: [], ignoredSignals: 0, caughtSignals: 0, nice: 0, shortName: "codex")
        }
        var runs = ActivityAgentRuns()
        runs.observe(try snapshot(context))
        let server = add(1700, parent: 1, name: "acme-server", environment: ["OVERTERM_TAB_ID=pane-a"])
        kernel.remove(1103)
        let after = try snapshot(context)
        runs.observe(after)
        context.agentRuns = runs.ended
        let owner = try XCTUnwrap(owners(after, context)[server])
        XCTAssertEqual(owner.place, .leftBehind)
        XCTAssertEqual(owner.certainty, .probably)
    }

    func testAPaneTheSnapshotDidntReadSaysNothingOfItsAgent() throws {
        let context = base()
        add(1103, parent: 1101, name: "claude", words: ["claude"], terminal: pty, group: 1103)
        var runs = ActivityAgentRuns()
        runs.observe(try snapshot(context))
        var unread = context
        unread.panes = []
        kernel.remove(1103)
        XCTAssertTrue(runs.observe(try snapshot(unread)).isEmpty, "not read is not ended")
        XCTAssertNotNil(runs.running["pane-a"])
        runs.forget(tag: "pane-a")
        XCTAssertTrue(runs.running.isEmpty, "a closed pane's run is the closed pane's to explain")
    }

    // MARK: Rule 11: the other signs

    func testAClosedPanesTagIsLeftBehind() throws {
        var context = base()
        context.retired = [retired("pane-gone")]
        let server = add(1800, parent: 1, name: "acme-server", environment: ["OVERTERM_TAB_ID=pane-gone"], port: 3001)
        let snapshot = try snapshot(context)
        let owner = try XCTUnwrap(owners(snapshot, context)[server])
        XCTAssertEqual(owner.place, .leftBehind)
        XCTAssertEqual(owner.rule, 11)
        XCTAssertEqual(owner.reason, "left by Claude in “api”, closed at \(LeftBehind.clock(Date(timeIntervalSince1970: 1_700_000_000)))")
        XCTAssertEqual(owner.leftBehind?.checkout, checkout)
        XCTAssertTrue(ActivityRows.isRunsOwnLeftover(owner), "a test run lists what its own closed panes left")
        XCTAssertTrue(ActivityRows.inScope(owner, .checkout(checkout), tabs: [:], context: context, identity: server))
        XCTAssertTrue(ActivityRows.inScope(owner, .allTabs, tabs: [:], context: context, identity: server))
        XCTAssertEqual(ActivityRows.Fixed.of(owner), .leftBehind)
        XCTAssertFalse(ActivityRows.Fixed.leftBehind.foldedByDefault)
    }

    func testWhatIsNeverLeftBehindWhateverTagItCarries() throws {
        var context = base()
        context.retired = [retired("pane-gone")]
        let tmux = add(1801, parent: 1, name: "tmux", environment: ["OVERTERM_TAB_ID=pane-gone"])
        let editor = add(
            1802, parent: 1, name: "Fake Editor", path: "/Applications/Fake Editor.app/Contents/MacOS/Fake Editor",
            environment: ["OVERTERM_TAB_ID=pane-gone"])
        let job = add(1803, parent: 1, name: "acme-agentd", environment: ["OVERTERM_TAB_ID=pane-gone", "XPC_SERVICE_NAME=homebrew.mxcl.acme"])
        let snapshot = try snapshot(context)
        let owners = owners(snapshot, context)
        for identity in [tmux, editor, job] {
            XCTAssertNotEqual(owners[identity]?.place, .leftBehind, "\(identity.pid)")
            XCTAssertNil(owners[identity]?.leftBehind, "\(identity.pid)")
        }
    }

    func testAKeptProcessIsTheUsersElsewhereSayingSo() throws {
        var context = base()
        context.retired = [retired("pane-gone", agent: nil)]
        let server = add(1800, parent: 1, name: "acme-server", environment: ["OVERTERM_TAB_ID=pane-gone"])
        context.kept = [server]
        let owner = try XCTUnwrap(owners(try snapshot(context), context)[server])
        XCTAssertEqual(owner.place, .elsewhere)
        XCTAssertTrue(owner.kept)
        XCTAssertTrue(owner.reason?.hasPrefix("kept running — left by “api”, closed at") == true, owner.reason ?? "")
    }

    func testWhatAKeptProcessStartedIsKeptWithIt() throws {
        var context = base()
        context.retired = [retired("pane-gone")]
        let server = add(1800, parent: 1, name: "acme-server", environment: ["OVERTERM_TAB_ID=pane-gone"])
        let worker = add(1801, parent: 1800, name: "acme-worker", environment: ["OVERTERM_TAB_ID=pane-gone"])
        context.kept = [server]
        let snapshot = try snapshot(context)
        let owners = owners(snapshot, context)
        XCTAssertEqual(owners[worker]?.place, .elsewhere, "a kept server's worker is never Left Behind")
        XCTAssertEqual(owners[worker]?.kept, true)
        let subject = try XCTUnwrap(ActivityVerbSubject.read(worker, in: snapshot, owners: owners, known: ActivityVerbSubject.Known(appPID: app)))
        XCTAssertEqual(
            LeftBehindStop.refusal(
                subject, process: try XCTUnwrap(snapshot.table.process(worker)), owner: owners[worker], pick: .bulk, kept: context.kept,
                table: snapshot.table, user: 501), LeftBehindStop.keptWords)
        let note = LeftBehind.left(
            by: ActivityAgentRun(tag: "pane-gone", tab: tab, agent: .claude, identity: server, lastSeen: 0, ended: Date(), foreground: true),
            in: snapshot, checkouts: [checkout], kept: context.kept)
        XCTAssertTrue(note.isEmpty)
    }

    func testARunFoundGoneLongAfterItsLastSightingIsOnlyProbably() {
        let agent = ActivityProcessID(pid: 1103, start: 1_000)
        var run = ActivityAgentRun(
            tag: "pane-a", tab: tab, agent: .claude, identity: agent, lastSeen: 2_000, ended: Date(timeIntervalSince1970: 3_600), foreground: true)
        XCTAssertEqual(LeftBehindSign.agentRun(run, title: "web").certainty, .certain)
        run.exact = false
        let sign = LeftBehindSign.agentRun(run, title: "web")
        XCTAssertEqual(sign.certainty, .probably, "a window covering what the person started meanwhile")
        XCTAssertTrue(sign.reason.contains("which exited by "), sign.reason)
    }

    func testAScenarioScratchSignIsATestRunsOnlyOnceOrphaned() throws {
        let context = base()
        let words = ["/usr/bin/perl", "/private/var/folders/x/T/overterm-e2e-\(UUID().uuidString)/stand-in-bin/port-forward.pl"]
        let running = add(1960, parent: 1101, name: "perl", path: "/usr/bin/perl", words: words, platform: true)
        let orphan = add(1961, parent: 1, name: "perl", path: "/usr/bin/perl", words: words, platform: true)
        let snapshot = try snapshot(context)
        func sign(_ identity: ActivityProcessID) throws -> LeftBehindSign? {
            LeftBehind.sign(
                of: try XCTUnwrap(snapshot.table.process(identity)), facts: snapshot.facts[identity], table: snapshot.table, context: context,
                live: ["pane-a"], checkouts: [checkout], openCheckouts: [checkout])
        }
        XCTAssertNil(try sign(running), "a running test's stand-in has its live parent")
        XCTAssertEqual(try sign(orphan), .testRun)
    }

    func testATabsLeftoversGatherAcrossItsRuns() throws {
        let context = base()
        let first = add(1700, parent: 1, name: "acme-server")
        let second = add(1701, parent: 1, name: "acme-worker")
        let gone = ActivityProcessID(pid: 1799, start: 1)
        let snapshot = try snapshot(context)
        let earlier = [LeftBehindItem(identity: first, name: "acme-server"), LeftBehindItem(identity: gone, name: "acme-gone")]
        XCTAssertEqual(LeftBehind.merged(earlier, [], in: snapshot, limit: 10).map(\.identity), [first], "a run that left nothing takes none")
        XCTAssertEqual(
            LeftBehind.merged(earlier, [LeftBehindItem(identity: second, name: "acme-worker")], in: snapshot, limit: 10).map(\.identity),
            [first, second])
    }

    func testAnEarlierOvertermsMarkerAndArgvSign() throws {
        let context = base()
        let released = add(1900, parent: 1, name: "acme-server", environment: ["OVERTERM_RUN=release.77.123", "OVERTERM_HELPER=managed"])
        let tested = add(1901, parent: 1, name: "acme-server", environment: ["OVERTERM_RUN=isolated.78.456"])
        let proxy = add(1902, parent: 1, name: "kubectl", words: ["kubectl", "proxy", "--unix-socket=/tmp/ot-kube-501-79-abc/proxy.sock"])
        let standIn = add(
            1903, parent: 1, name: "perl", path: "/usr/bin/perl",
            words: ["/usr/bin/perl", "/private/var/folders/x/T/overterm-e2e-\(UUID().uuidString)/stand-in-bin/port-forward.pl"], platform: true)
        // This run's own sign, and a live run's marker: neither.
        let own = add(1904, parent: 1, name: "kubectl", words: ["kubectl", "proxy", "--unix-socket=/tmp/ot-kube-501-1000-\(OvertermRun.base36(1_000_000))/p.sock"])
        let live = add(1905, parent: 1, name: "acme-server", environment: ["OVERTERM_RUN=dev.1100.\(UInt64(1100) * 1_000)"])
        let snapshot = try snapshot(context)
        let owners = owners(snapshot, context)
        XCTAssertEqual(owners[released]?.leftBehind, .earlierRun(.release))
        XCTAssertEqual(owners[released]?.reason, "left by Overterm’s earlier run")
        XCTAssertEqual(owners[tested]?.leftBehind, .testRun)
        XCTAssertEqual(owners[tested]?.reason, "left by a test run")
        XCTAssertEqual(owners[proxy]?.leftBehind, .earlierRun(nil))
        XCTAssertEqual(owners[standIn]?.leftBehind, .testRun)
        XCTAssertNil(owners[own]?.leftBehind, "this run's own sign")
        XCTAssertNil(owners[live]?.leftBehind, "a live run's marker")
        XCTAssertTrue(owners[released]?.leftBehind?.isEarlierRun == true)
        XCTAssertFalse(ActivityRows.isRunsOwnLeftover(owners[released]), "a test run doesn't list another run's")
    }

    func testADeadGroupLeadersOrphanInACheckoutNoTabShowsIsProbably() throws {
        let context = base()
        let orphan = add(2000, parent: 1, name: "acme-watch", group: 1990)
        let snapshot = try snapshot(context)
        let process = try XCTUnwrap(snapshot.table.process(orphan))
        var facts = snapshot.facts[orphan] ?? ActivityFacts(name: "acme-watch")
        facts.folder = .path(checkout + "/web")
        let sign = LeftBehind.sign(
            of: process, facts: facts, table: snapshot.table, context: context, live: ["pane-a"], checkouts: [checkout], openCheckouts: [])
        XCTAssertEqual(sign, .deadLeader(checkout: checkout))
        XCTAssertEqual(sign?.certainty, .probably)
        XCTAssertNil(
            LeftBehind.sign(
                of: process, facts: facts, table: snapshot.table, context: context, live: ["pane-a"], checkouts: [checkout],
                openCheckouts: [checkout]), "a tab shows the checkout")
        facts.folder = .path("/Users/fake/elsewhere")
        XCTAssertNil(
            LeftBehind.sign(
                of: process, facts: facts, table: snapshot.table, context: context, live: ["pane-a"], checkouts: [checkout], openCheckouts: []))
    }

    // MARK: The class, the bulk

    func testALeftBehindProcessIsItsOwnClassAndOnlyCertainOnesAreBulk() throws {
        var context = base()
        context.retired = [retired("pane-gone")]
        let server = add(1800, parent: 1, name: "acme-server", environment: ["OVERTERM_TAB_ID=pane-gone"])
        let nohup = add(1801, parent: 1, name: "acme-worker", environment: ["OVERTERM_TAB_ID=pane-gone"], ignoresHangup: true)
        let snapshot = try snapshot(context)
        let owners = owners(snapshot, context)
        let subject = try XCTUnwrap(ActivityVerbSubject.read(server, in: snapshot, owners: owners, known: ActivityVerbSubject.Known()))
        XCTAssertEqual(subject.target.kind, .leftBehind)
        let serverOwner = try XCTUnwrap(owners[server])
        let nohupOwner = try XCTUnwrap(owners[nohup])
        XCTAssertEqual(nohupOwner.place, .leftBehind, "listed where its sign puts it")
        XCTAssertTrue(nohupOwner.marks.contains(.nohup))
        XCTAssertTrue(LeftBehind.isBulkEligible(serverOwner, process: try XCTUnwrap(snapshot.table.process(server)), terraformWrite: false, kept: false))
        XCTAssertFalse(LeftBehind.isBulkEligible(nohupOwner, process: try XCTUnwrap(snapshot.table.process(nohup)), terraformWrite: false, kept: false))
        XCTAssertFalse(LeftBehind.isBulkEligible(serverOwner, process: try XCTUnwrap(snapshot.table.process(server)), terraformWrite: true, kept: false))
        XCTAssertFalse(LeftBehind.isBulkEligible(serverOwner, process: try XCTUnwrap(snapshot.table.process(server)), terraformWrite: false, kept: true))
        var probably = serverOwner
        probably.certainty = .probably
        XCTAssertFalse(LeftBehind.isBulkEligible(probably, process: try XCTUnwrap(snapshot.table.process(server)), terraformWrite: false, kept: false))
    }

    func testANoteWithNothingLeftSaysOnlyThatItFinished() {
        XCTAssertEqual(LeftBehind.note(.codex, left: []), "Codex finished")
        let item = LeftBehindItem(identity: ActivityProcessID(pid: 4242, start: 1), name: "acme-sleep")
        XCTAssertEqual(LeftBehind.note(.claude, left: [item]), "Claude finished — left acme-sleep running")
    }

    func testEveryLeftBehindStopAsksThePolicyAgainAtTheButton() throws {
        var context = base()
        context.retired = [retired("pane-gone")]
        let server = add(1800, parent: 1, name: "acme-server", environment: ["OVERTERM_TAB_ID=pane-gone"])
        let apply = add(1801, parent: 1, name: "terraform", words: ["terraform", "apply"], environment: ["OVERTERM_TAB_ID=pane-gone"])
        let nohup = add(1802, parent: 1, name: "acme-worker", environment: ["OVERTERM_TAB_ID=pane-gone"], ignoresHangup: true)
        let kept = add(1803, parent: 1, name: "acme-keep", environment: ["OVERTERM_TAB_ID=pane-gone"])
        context.kept = [kept]
        let snapshot = try snapshot(context)
        let owners = owners(snapshot, context)
        let ended = ActivitySignalTarget(ActivityProcessID(pid: 1899, start: 1), path: nil)
        let targets = [server, apply, nohup, kept].map { ActivitySignalTarget($0, path: snapshot.facts[$0]?.path) } + [ended]
        func check(_ pick: LeftBehindStop.Pick) -> LeftBehindStop.Checked {
            LeftBehindStop.check(targets, pick: pick, in: snapshot, owners: owners, known: ActivityVerbSubject.Known(appPID: app), kept: context.kept)
        }
        let bulk = check(.bulk)
        XCTAssertEqual(bulk.send.map(\.identity), [server])
        let reasons = Dictionary(uniqueKeysWithValues: bulk.refused.map { ($0.target.identity, $0.reason) })
        XCTAssertTrue(reasons[apply]?.contains("terraform") == true)
        XCTAssertNotNil(reasons[nohup], "what chose to outlive its terminal is picked alone")
        XCTAssertEqual(reasons[kept], LeftBehindStop.keptWords)
        XCTAssertEqual(reasons[ended.identity], LeftBehindStop.endedWords)
        XCTAssertEqual(check(.certain).send.map(\.identity), [server])
        // Ticked one by one in a close sheet: the Stop rule alone — the
        // nohup'd one may go, a terraform write never.
        let picked = check(.picked)
        XCTAssertEqual(Set(picked.send.map(\.identity)), [server, nohup])
        XCTAssertTrue(picked.refused.contains { $0.target.identity == apply && $0.reason.contains("terraform") })
    }

    // MARK: The section

    func testTheSectionGroupsByCheckoutAndCountsTheCertain() throws {
        var context = base()
        context.retired = [retired("pane-gone")]
        let server = add(1800, parent: 1, name: "acme-server", environment: ["OVERTERM_TAB_ID=pane-gone"], port: 3001)
        let nohup = add(1801, parent: 1, name: "acme-worker", environment: ["OVERTERM_TAB_ID=pane-gone"], ignoresHangup: true)
        let earlier = add(1900, parent: 1, name: "acme-proxy", environment: ["OVERTERM_RUN=release.77.123"])
        let snapshot = try snapshot(context)
        var options = ActivityRows.Options()
        options.context = context
        options.tabs = [tab: ActivityTabFacts(id: tab, title: "web", checkout: checkout)]
        options.checkouts = [checkout]
        options.grouping = .checkout
        let content = ActivityRows.content(of: snapshot, options)
        XCTAssertEqual(content.summary.leftBehind, 3)
        let headers = content.leftBehind.compactMap { item -> ActivityGroupRow? in if case .group(let row) = item { row } else { nil } }
        XCTAssertEqual(headers.map(\.title), ["acme-shop", "Left by an earlier Overterm"], "checkouts first, then the fixed groups")
        XCTAssertEqual(headers.first?.count, 2)
        XCTAssertEqual(headers.first?.detail, "1 certain")
        XCTAssertEqual(headers.first?.ports, [3001])
        let rows = content.processes
        let serverRow = try XCTUnwrap(rows.first { $0.identity == server })
        XCTAssertTrue(serverRow.bulkEligible)
        XCTAssertFalse(try XCTUnwrap(rows.first { $0.identity == nohup }).bulkEligible, "ignoring SIGHUP: picked by hand")
        XCTAssertEqual(ActivityRows.certainInGroup(of: serverRow, in: rows, tabs: options.tabs).map(\.identity), [server])
        let earlierRow = try XCTUnwrap(rows.first { $0.identity == earlier })
        XCTAssertEqual(ActivityRows.certainInGroup(of: earlierRow, in: rows, tabs: options.tabs).map(\.identity), [earlier], "its own group's")
        // Processes lists them in a group of their own, unfolded.
        XCTAssertTrue(content.list.contains { if case .group(let row) = $0 { row.id == ActivityRows.Fixed.leftBehind.id && !row.folded } else { false } })
    }

    // MARK: The close sheet (D-16)

    func testTheCloseSheetNeverOffersATerraformACheckbox() throws {
        let context = base()
        let apply = add(1700, parent: 1, name: "terraform", words: ["terraform", "apply"], environment: ["OVERTERM_TAB_ID=pane-a"])
        let snapshot = try snapshot(context)
        let survivors = ActivitySurvivors.of(["pane-a"], in: snapshot, terminals: ["pane-a": pty], checkouts: [checkout])
        XCTAssertEqual(survivors.interruptOnly.map(\.identity), [apply])
        XCTAssertTrue(survivors.all.isEmpty, "no checkbox")
        XCTAssertTrue(survivors.anyKeepRunning)
        XCTAssertTrue(survivors.listed.contains("Terraform goes on: terraform (pid 1700)"))
        XCTAssertFalse(survivors.said.contains("Tick what to stop"), "nothing to tick")
    }

    private func foreground(_ pid: pid_t, is group: pid_t) {
        kernel.update(pid) { process in
            let record = process.record
            process.record = ActivityProcess(
                identity: record.identity, parentPID: record.parentPID, group: record.group, terminal: record.terminal, terminalGroup: group,
                effectiveUID: record.effectiveUID, realUID: record.realUID, savedUID: record.savedUID, status: record.status, flags: record.flags,
                ignoredSignals: record.ignoredSignals, caughtSignals: record.caughtSignals, nice: record.nice, shortName: record.shortName)
        }
    }

    func testTheCloseSheetNamesWhatKeepsRunningAndWhatItsShellDecides() throws {
        let context = base()
        // A foreground job: the close ends it, not listed.
        add(1110, parent: 1101, name: "acme-build", terminal: pty, group: 1110)
        // A background job: its shell decides.
        let background = add(1120, parent: 1101, name: "acme-watch", terminal: pty, group: 1120)
        foreground(1120, is: 1110)
        foreground(1101, is: 1110)
        // setsid'd under the shell, no terminal: keeps running.
        let detached = add(1130, parent: 1101, name: "acme-daemon", group: 1130, port: 4000)
        // Left the terminal carrying the tag: keeps running.
        let left = add(1700, parent: 1, name: "acme-server", environment: ["OVERTERM_TAB_ID=pane-a"], port: 3001)
        // nohup'd in the tree: keeps running, listed.
        let nohup = add(1140, parent: 1101, name: "acme-worker", terminal: pty, group: 1140, ignoresHangup: true)
        foreground(1140, is: 1110)
        // tmux and an app started here: not affected.
        add(1300, parent: 1, name: "tmux", environment: ["OVERTERM_TAB_ID=pane-a"])
        add(
            1400, parent: 1, name: "Fake Editor", path: "/Applications/Fake Editor.app/Contents/MacOS/Fake Editor",
            environment: ["OVERTERM_TAB_ID=pane-a"])
        let snapshot = try snapshot(context)
        let survivors = ActivitySurvivors.of(["pane-a"], in: snapshot, terminals: ["pane-a": pty], checkouts: [checkout])
        XCTAssertEqual(Set(survivors.keepRunning.map(\.identity)), [detached, left, nohup])
        XCTAssertEqual(survivors.shellDecides.map(\.identity), [background])
        XCTAssertEqual(Set(survivors.unaffected), ["tmux", "Fake Editor"])
        XCTAssertEqual(survivors.keepRunning.first { $0.identity == left }?.label, "acme-server (pid 1700) :3001")
        XCTAssertTrue(survivors.keepRunning.first { $0.identity == nohup }?.nohup == true)
        XCTAssertTrue(survivors.said.contains("Will keep running: "))
        XCTAssertTrue(survivors.said.contains("Its shell decides: acme-watch (pid 1120)"))
        XCTAssertTrue(survivors.said.contains("started here, are not affected."))
        let kept = ActivitySurvivors.of(["pane-a"], in: snapshot, terminals: ["pane-a": pty], checkouts: [checkout], kept: [left])
        XCTAssertFalse(kept.keepRunning.contains { $0.identity == left }, "one kept isn't asked about again")
        XCTAssertTrue(ActivitySurvivors.of(["pane-b"], in: snapshot).isEmpty, "a pane the census didn't read says nothing")
    }

    // MARK: Removing a worktree

    func testAWorktreesKeptAndTerraformAreNeverStoppedAndBothPathsAreOneSweep() throws {
        var context = base()
        let worktree = "/Users/fake/src/acme-shop/.worktrees/feature-y"
        let resolved = "/private/fake/acme-shop/.worktrees/feature-y"
        let kept = add(1700, parent: 1, name: "acme-server")
        kernel.update(1700) { $0.folder = worktree }
        let worker = add(1701, parent: 1700, name: "acme-worker")
        kernel.update(1701) { $0.folder = resolved + "/web" }
        let apply = add(1710, parent: 1, name: "terraform", words: ["terraform", "apply"])
        kernel.update(1710) { $0.folder = worktree + "/infra" }
        let other = add(1720, parent: 1, name: "acme-watch")
        kernel.update(1720) { $0.folder = worktree }
        context.kept = [kept]
        let snapshot = try snapshot(context)
        let read = WorktreeProcesses.read([worktree, resolved], in: snapshot, kernel: kernel, app: app, deadline: .max, kept: context.kept)
        XCTAssertTrue(read.complete)
        XCTAssertEqual(read.found.map(\.identity).sorted(), [kept, worker, apply, other].sorted(), "each once")
        let excluded = Dictionary(uniqueKeysWithValues: read.found.map { ($0.identity, $0.excluded) })
        XCTAssertEqual(excluded[kept] ?? nil, "you kept it")
        XCTAssertEqual(excluded[worker] ?? nil, "you kept it", "what a kept one started")
        XCTAssertEqual(excluded[apply] ?? nil, "terraform: Interrupt it alone, from Activity")
        XCTAssertNil(excluded[other] ?? nil)
        // A test run lists only its own (9.9).
        let own = WorktreeProcesses.runsOwn(in: snapshot, tags: ["pane-a"], run: context.run, gate: ActivitySignalGate(guards: true))
        let scoped = WorktreeProcesses.read([worktree, resolved], in: snapshot, kernel: kernel, app: app, deadline: .max, only: own)
        XCTAssertTrue(scoped.found.isEmpty, "none of them is the run's")
        let gate = ActivitySignalGate(guards: true)
        gate.register(other)
        let registered = WorktreeProcesses.runsOwn(in: snapshot, tags: ["pane-a"], run: context.run, gate: gate)
        XCTAssertEqual(
            WorktreeProcesses.read([worktree], in: snapshot, kernel: kernel, app: app, deadline: .max, only: registered).found.map(\.identity), [other])
    }

    func testAWorktreesProcessesByFolderAndOpenFile() throws {
        let context = base()
        let worktree = "/Users/fake/src/acme-shop/.worktrees/feature-x"
        let server = add(1700, parent: 1, name: "acme-server")
        kernel.update(1700) { $0.folder = worktree + "/web" }
        let database = add(1710, parent: 1, name: "acme-db")
        kernel.update(1710) { process in
            process.folder = "/Users/fake"
            process.descriptors = [FakeActivityKernel.descriptor(3, socket: false), FakeActivityKernel.descriptor(4, socket: false)]
            process.files = [3: "/Users/fake/notes.txt", 4: worktree + "/data/pg.pid"]
        }
        let nohup = add(1720, parent: 1, name: "acme-watch", ignoresHangup: true)
        kernel.update(1720) { $0.folder = worktree }
        let tmux = add(1730, parent: 1, name: "tmux")
        kernel.update(1730) { $0.folder = worktree }
        // Elsewhere, and one beside it whose name only starts the same.
        add(1740, parent: 1, name: "acme-other")
        kernel.update(1740) { $0.folder = worktree + "-old" }
        // Overterm's own helper there: never listed.
        add(1750, parent: app, name: "git", path: "/usr/bin/git", platform: true)
        kernel.update(1750) { $0.folder = worktree }
        let snapshot = try snapshot(context)
        let read = WorktreeProcesses.read(worktree, in: snapshot, kernel: kernel, app: app, deadline: .max)
        XCTAssertTrue(read.complete)
        XCTAssertEqual(Set(read.found.map(\.identity)), [server, database, nohup, tmux])
        XCTAssertEqual(read.found.first { $0.identity == server }?.via, .folder)
        XCTAssertEqual(read.found.first { $0.identity == database }?.via, .file)
        XCTAssertNil(read.found.first { $0.identity == server }?.excluded)
        XCTAssertEqual(read.found.first { $0.identity == nohup }?.excluded, "it ignores SIGHUP")
        XCTAssertEqual(read.found.first { $0.identity == tmux }?.excluded, "detached on purpose")
        XCTAssertEqual(read.found.first { $0.identity == database }?.line, "acme-db (pid 1710) — a file open inside")
        let late = WorktreeProcesses.read(worktree, in: snapshot, kernel: kernel, app: app, deadline: 0)
        XCTAssertFalse(late.complete, "past its deadline it says so")
    }

    // MARK: The launch check (D-14)

    func testTheLaunchsStopAllLeavesTerraformOut() throws {
        let context = base()
        let terraform = add(
            1940, parent: 1, name: "terraform", words: ["terraform", "apply", "-auto-approve"], environment: ["OVERTERM_RUN=release.77.123"])
        let proxy = add(1941, parent: 1, name: "kubectl", environment: ["OVERTERM_RUN=release.77.123"])
        let snapshot = try snapshot(context)
        let found = LeftBehindAtLaunch.of(snapshot, owners: owners(snapshot, context))
        XCTAssertEqual(found.earlier.first { $0.identity == terraform }?.stops, false, "Interrupt only, never in a Stop All")
        XCTAssertEqual(found.earlier.first { $0.identity == proxy }?.stops, true)
    }

    func testTheLaunchListsAnEarlierRunsAndATestRunsApartAndStopsNothingUnasked() throws {
        var context = base()
        let proxies = (0..<3).map { add(1900 + Int32($0), parent: 1, name: "kubectl", environment: ["OVERTERM_RUN=release.77.123"]) }
        let nohup = add(1910, parent: 1, name: "acme-worker", environment: ["OVERTERM_RUN=release.77.123"], ignoresHangup: true)
        let standIn = add(1920, parent: 1, name: "perl", environment: ["OVERTERM_RUN=isolated.78.456"])
        let kept = add(1930, parent: 1, name: "acme-keep", environment: ["OVERTERM_RUN=release.77.123"])
        context.kept = [kept]
        let snapshot = try snapshot(context)
        let found = LeftBehindAtLaunch.of(snapshot, owners: owners(snapshot, context))
        XCTAssertEqual(Set(found.earlier.map(\.identity)), Set(proxies + [nohup]))
        XCTAssertEqual(found.test.map(\.identity), [standIn])
        XCTAssertFalse(found.all.contains { $0.identity == kept }, "kept: left out")
        XCTAssertEqual(found.all.filter(\.stops).count, 4, "what ignores SIGHUP is listed, never in the Stop All")
        XCTAssertEqual(found.title, "Overterm’s earlier run left 3 kubectl, 1 acme-worker")
        XCTAssertTrue(found.detail.contains("Left by a test run: 1 perl."))
        XCTAssertTrue(found.detail.contains("Not in Stop All — they ignore SIGHUP, are terraform's or are only probably its: 1 acme-worker."))
        XCTAssertTrue(LeftBehindAtLaunch().isEmpty)
    }
}
