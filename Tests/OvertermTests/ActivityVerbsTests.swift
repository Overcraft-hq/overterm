import Darwin
import XCTest

@testable import Overterm

/// The page's verbs over a fake Mac (docs/design/activity/analysis.md,
/// 6.10, 10.1): a row's process read as the policy sees it — its class by
/// its owner, a terraform write, its tree and group, its supervisor —, the
/// sheet's words for each verb, and what `k` does by class. Nothing is
/// signalled here: the reads are a fake kernel's.
final class ActivityVerbsTests: XCTestCase {
    private let tty: dev_t = 0x1000_0007
    private let tag = "pane-a"
    private let tab = UUID()
    private var kernel = FakeActivityKernel(uid: 501)
    private let utc = TimeZone(identifier: "UTC")!

    override func setUp() {
        super.setUp()
        kernel = FakeActivityKernel(uid: 501)
        add(1, parent: 0, uid: 0, name: "launchd")
        add(1000, parent: 1, name: "Overterm")
        add(1100, parent: 1000, uid: 0, terminal: tty, name: "login")
        add(1101, parent: 1100, group: 1101, terminal: tty, name: "zsh")
    }

    @discardableResult
    private func add(
        _ pid: pid_t, parent: pid_t, uid: uid_t = 501, group: pid_t? = nil, terminal: dev_t? = nil, foreground: pid_t? = nil, status: Int32 = SRUN,
        name: String, argv: [String]? = nil
    ) -> ActivityProcessID {
        let start = UInt64(pid) * 1_000
        var record = FakeActivityKernel.record(
            pid: pid, start: start, parent: parent, uid: uid, realUID: uid == 0 ? 501 : nil, group: group, terminal: terminal, status: status, name: name)
        if let foreground {
            record = ActivityProcess(
                identity: record.identity, parentPID: record.parentPID, group: record.group, terminal: record.terminal, terminalGroup: foreground,
                effectiveUID: record.effectiveUID, realUID: record.realUID, savedUID: record.savedUID, status: record.status, flags: record.flags,
                ignoredSignals: record.ignoredSignals, caughtSignals: record.caughtSignals, nice: record.nice, shortName: record.shortName)
        }
        var process = FakeActivityKernel.Process(record: record)
        let executable = "/opt/acme/bin/\(name)"
        process.name = name
        process.path = executable
        process.arguments = FakeActivityKernel.arguments(executable: executable, argv ?? [name])
        kernel.add(process)
        return ActivityProcessID(pid: pid, start: start)
    }

    private func subject(_ identity: ActivityProcessID, known: ActivityVerbSubject.Known = .init(appPID: 1000)) throws -> ActivityVerbSubject {
        let context = ActivityContext(panes: [ActivityContext.Pane(tag: tag, tab: tab, login: ActivityProcessID(pid: 1100, start: 1_100_000))], appPID: 1000)
        let snapshot = try XCTUnwrap(ActivitySampler(kernel: kernel).tickNow(ActivityDemand(.full), context: context))
        let owners = ActivityAttribution.of(snapshot, context: context, inputs: .init(tabs: [tab: ActivityTabFacts(id: tab, title: "web")]))
        return try XCTUnwrap(ActivityVerbSubject.read(identity, in: snapshot, owners: owners, known: known))
    }

    // MARK: A row's process, as the policy sees it

    /// The pane's foreground job, a background one, the shell, the login,
    /// Overterm: their classes and facts, and what `k` does to each.
    func testClassesAndWhatKDoes() throws {
        let server = add(1102, parent: 1101, group: 1102, terminal: tty, foreground: 1102, name: "acme-dev")
        let worker = add(1103, parent: 1101, group: 1103, terminal: tty, foreground: 1102, name: "acme-worker")
        let fg = try subject(server)
        XCTAssertEqual(fg.target.kind, .paneJob)
        XCTAssertTrue(fg.target.inForeground)
        XCTAssertEqual(fg.pane, tag)
        XCTAssertEqual(ActivityPageModel.stopVerb(for: fg.target), .interrupt)
        let bg = try subject(worker)
        XCTAssertFalse(bg.target.inForeground)
        XCTAssertEqual(ActivityPageModel.stopVerb(for: bg.target), .stop)
        XCTAssertEqual(ActivitySignalCheck.rule(.interrupt, for: bg.target, user: 501).refusal, ActivitySignalCheck.notForeground)
        let shell = try subject(ActivityProcessID(pid: 1101, start: 1_101_000))
        XCTAssertEqual(shell.target.kind, .paneSession)
        XCTAssertEqual(ActivitySignalCheck.rule(.stop, for: shell.target, user: 501), .route(.closePane, confirm: true))
        let login = try subject(ActivityProcessID(pid: 1100, start: 1_100_000))
        XCTAssertEqual(login.target.kind, .paneSession)
        XCTAssertEqual(try subject(ActivityProcessID(pid: 1000, start: 1_000_000)).target.kind, .overterm)
    }

    /// The agent and what runs under it: ⌃C would reach the agent.
    func testTheAgentAndItsChildren() throws {
        let agent = add(1110, parent: 1101, group: 1110, terminal: tty, foreground: 1110, name: "claude", argv: ["claude"])
        let mcp = add(1111, parent: 1110, group: 1110, terminal: tty, foreground: 1110, name: "acme-mcp")
        let read = try subject(agent)
        XCTAssertEqual(read.target.kind, .agent)
        XCTAssertEqual(read.agent, .claude)
        XCTAssertEqual(ActivityPageModel.stopVerb(for: read.target), .stopAgent)
        XCTAssertEqual(ActivitySignalCheck.rule(.interruptTurn, for: read.target, user: 501), .allowed(.interruptPane, confirm: true, critical: false))
        let child = try subject(mcp)
        XCTAssertEqual(child.target.kind, .agentChild)
        XCTAssertTrue(child.target.groupHoldsAgent)
        XCTAssertEqual(ActivitySignalCheck.rule(.interrupt, for: child.target, user: 501).refusal, ActivitySignalCheck.underAgent)
        XCTAssertEqual(ActivityPageModel.stopVerb(for: child.target), .stop)
        let turn = try XCTUnwrap(ActivityVerbQuestion.question(.interruptTurn, ActivitySignalCheck.rule(.interruptTurn, for: read.target, user: 501), subject: read, scope: nil))
        XCTAssertEqual(turn.title, "Interrupt Claude's turn?")
        XCTAssertFalse(turn.critical, "plain")
        let stop = try XCTUnwrap(ActivityVerbQuestion.question(.stopAgent, ActivitySignalCheck.rule(.stopAgent, for: read.target, user: 501), subject: read, scope: nil))
        XCTAssertEqual(stop.button, "Stop Agent")
        XCTAssertTrue(stop.critical)
        XCTAssertTrue(stop.detail.contains("claude --continue"), stop.detail)
    }

    /// A terraform write, by its masked argv: Interrupt only.
    func testATerraformWriteIsReadFromItsArgv() throws {
        let apply = add(1120, parent: 1101, group: 1120, terminal: tty, foreground: 1120, name: "terraform", argv: ["terraform", "apply", "-auto-approve"])
        let plan = add(1121, parent: 1101, group: 1121, terminal: tty, foreground: 1120, name: "terraform", argv: ["terraform", "plan"])
        let write = try subject(apply)
        XCTAssertEqual(write.target.terraformWrite, "terraform apply")
        XCTAssertEqual(ActivityPageModel.stopVerb(for: write.target), .interrupt)
        XCTAssertEqual(ActivitySignalCheck.rule(.forceQuit, for: write.target, user: 501).refusal, ActivitySignalCheck.terraformKill)
        XCTAssertNil(try subject(plan).target.terraformWrite, "a plan writes nothing")
    }

    /// A tree, parents first, what a bulk leaves out; its group; its
    /// supervisor named; the sheet's words.
    func testATreeItsGroupAndItsSupervisor() throws {
        let supervisor = add(1130, parent: 1101, group: 1130, terminal: tty, foreground: 1101, name: "acme-supervisor")
        let server = add(1131, parent: 1130, group: 1130, terminal: tty, foreground: 1101, name: "acme-server")
        add(1132, parent: 1131, group: 1130, terminal: tty, foreground: 1101, name: "acme-worker")
        add(1133, parent: 1131, group: 1130, terminal: tty, foreground: 1101, name: "terraform", argv: ["terraform", "apply"])
        add(1134, parent: 1101, group: 1130, terminal: tty, foreground: 1101, name: "acme-sibling")
        let root = try subject(supervisor)
        XCTAssertEqual(root.tree.map(\.signal.identity.pid), [1131, 1132, 1133], "parents first")
        XCTAssertEqual(root.tree.filter { $0.refusal != nil }.map(\.signal.identity.pid), [1133], "a terraform write in no bulk")
        XCTAssertTrue(root.target.leadsGroup)
        XCTAssertTrue(root.target.groupBeyondTree, "the sibling is in its group, not its tree")
        XCTAssertEqual(root.target.groupHolds, "a terraform write")
        XCTAssertNotNil(ActivitySignalCheck.rule(.stopGroup, for: root.target, user: 501).refusal)
        let rule = ActivitySignalCheck.rule(.stopTree, for: root.target, user: 501)
        let sheet = try XCTUnwrap(ActivityVerbQuestion.question(.stopTree, rule, subject: root, scope: "Tab “web”", timeZone: utc))
        XCTAssertEqual(sheet.title, "Stop “acme-supervisor” (pid 1130) and its tree — 3 processes?")
        XCTAssertEqual(sheet.button, "Stop 3 Processes")
        XCTAssertTrue(sheet.detail.contains("pid 1133 terraform — a terraform write: Interrupt it alone"), sheet.detail)
        XCTAssertTrue(sheet.detail.contains("The command it equals: kill -TERM 1130 1131 1132"), sheet.detail)
        let child = try subject(server)
        XCTAssertEqual(child.supervisor?.pid, 1130, "its parent may start it again")
        let stop = try XCTUnwrap(ActivityVerbQuestion.question(.stop, ActivitySignalCheck.rule(.stop, for: child.target, user: 501), subject: child, scope: nil, timeZone: utc))
        XCTAssertEqual(stop.title, "Stop “acme-server” (pid 1131)?")
        XCTAssertTrue(stop.detail.contains("“acme-supervisor” (pid 1130), its parent, may start it again"), stop.detail)
        XCTAssertTrue(stop.detail.contains("Its 2 children keep running"), stop.detail)
        XCTAssertTrue(stop.detail.contains("The command it equals: kill -TERM 1131"), stop.detail)
        XCTAssertFalse(stop.critical)
    }

    /// A zombie: refused; Stop Its Parent through its parent's own class.
    func testAZombiesParent() throws {
        let parent = add(1140, parent: 1101, group: 1140, terminal: tty, foreground: 1101, name: "acme-parent")
        let zombie = add(1141, parent: 1140, group: 1140, terminal: tty, foreground: 1101, status: SZOMB, name: "acme-child")
        let read = try subject(zombie)
        XCTAssertTrue(read.target.isZombie)
        XCTAssertEqual(read.parent, parent)
        XCTAssertEqual(ActivitySignalCheck.rule(.stop, for: read.target, user: 501).refusal, ActivitySignalCheck.ended)
        XCTAssertEqual(
            ActivitySignalCheck.rule(.stopParent, for: read.target, parent: read.parentTarget, user: 501), .allowed(.signal(.term), confirm: true, critical: false))
        let shellChild = try subject(parent)
        XCTAssertEqual(
            ActivitySignalCheck.rule(.stopParent, for: shellChild.target, parent: shellChild.parentTarget, user: 501), .route(.closePane, confirm: true),
            "a shell's: its pane's close")
    }

    /// Who stopped a stopped process: Activity, Suspend Tab, job control.
    func testWhoStoppedIt() throws {
        let job = add(1150, parent: 1101, group: 1150, terminal: tty, foreground: 1101, status: SSTOP, name: "acme-job")
        XCTAssertEqual(try subject(job).target.stopped, .jobControl)
        XCTAssertEqual(try subject(job, known: .init(appPID: 1000, stoppedHere: [job])).target.stopped, .activity)
        XCTAssertEqual(try subject(job, known: .init(appPID: 1000, suspendedTab: [job])).target.stopped, .suspendTab)
        let stopped = try subject(job)
        let sheet = try XCTUnwrap(ActivityVerbQuestion.question(.stop, ActivitySignalCheck.rule(.stop, for: stopped.target, user: 501), subject: stopped, scope: nil))
        XCTAssertTrue(sheet.detail.contains("It is stopped: it is continued right after"), sheet.detail)
    }

    /// Send a Signal's and Force Quit's words; the count typed past 50.
    func testSignalWords() throws {
        let node = add(1160, parent: 1101, group: 1160, terminal: tty, foreground: 1101, name: "node", argv: ["node", "server.js"])
        let read = try subject(node)
        let usr1 = try XCTUnwrap(ActivityVerbQuestion.question(.send(.usr1), ActivitySignalCheck.rule(.send(.usr1), for: read.target, user: 501), subject: read, scope: nil))
        XCTAssertEqual(usr1.title, "Send SIGUSR1 to “node” (pid 1160)?")
        XCTAssertTrue(usr1.detail.contains("127.0.0.1:9229"), usr1.detail)
        let kill = try XCTUnwrap(ActivityVerbQuestion.question(.forceQuit, ActivitySignalCheck.rule(.forceQuit, for: read.target, user: 501), subject: read, scope: nil))
        XCTAssertEqual(kill.button, "Force Quit")
        XCTAssertTrue(kill.critical)
        XCTAssertTrue(kill.detail.contains("kill -KILL 1160"), kill.detail)
        XCTAssertFalse(ActivityVerbQuestion.typesCount(50))
        XCTAssertTrue(ActivityVerbQuestion.typesCount(51))
        XCTAssertEqual(ActivityVerbQuestion.stopFirst(read).title, "SIGKILL skips its cleanup: pid files, children. Stop it first?")
    }

    /// Force Quit is offered plainly for two minutes after a Stop (D-11),
    /// and the stops kept are the last two minutes' only.
    @MainActor func testForceQuitsWindowAfterAStop() {
        let page = ActivityPageModel(monitor: ActivityMonitor(sampler: ActivitySampler(kernel: kernel)))
        let identity = ActivityProcessID(pid: 1170, start: 1)
        let now = Date()
        XCTAssertFalse(page.recentlyStopped(identity, now: now))
        page.noteStopped(identity, at: now)
        XCTAssertTrue(page.recentlyStopped(identity, now: now + 119))
        XCTAssertFalse(page.recentlyStopped(identity, now: now + 121))
        for pid: pid_t in 1171...1180 { page.noteStopped(ActivityProcessID(pid: pid, start: 1), at: now + 1) }
        page.noteStopped(ActivityProcessID(pid: 1181, start: 1), at: now + 200)
        XCTAssertEqual(page.stoppedAt.count, 1, "what is past its two minutes goes as the next is noted")
    }

    /// Send a Signal ▸ STOP and CONT, a pane's job's Suspend, the
    /// priorities: greyed with the step they come with — never offered and
    /// then refused as an owner's verb on another page.
    func testSuspendAndPrioritiesAreGreyedWithTheirOwnStep() throws {
        let job = add(1180, parent: 1101, group: 1180, terminal: tty, foreground: 1101, name: "acme-job")
        let elsewhere = add(1181, parent: 1, group: 1181, name: "acme-daemon")
        for identity in [job, elsewhere] {
            let read = try subject(identity)
            for verb in [ActivityVerb.send(.stop), .suspend, .background, .lowerPriority] {
                let rule = ActivitySignalCheck.rule(verb, for: read.target, user: 501)
                XCTAssertEqual(ActivityPageModel.unavailable(rule), ActivityPageModel.suspendLater, "\(verb) of \(read.target.kind)")
            }
        }
        var stopped = try subject(elsewhere).target
        stopped.stopped = .activity
        XCTAssertEqual(ActivityPageModel.unavailable(ActivitySignalCheck.rule(.send(.cont), for: stopped, user: 501)), ActivityPageModel.suspendLater)
        let read = try subject(elsewhere)
        XCTAssertNil(ActivityPageModel.unavailable(ActivitySignalCheck.rule(.send(.hup), for: read.target, user: 501)), "SIGHUP is offered")
        let shell = try subject(ActivityProcessID(pid: 1101, start: 1_101_000))
        XCTAssertNil(ActivityPageModel.unavailable(ActivitySignalCheck.rule(.stop, for: shell.target, user: 501)), "the pane's close is the page's own route")
    }

    /// Stop Its Tree at the button: the members as the sheet listed them —
    /// one that exec'd since keeps the listed executable, so its send is
    /// "ran another program", never a TERM to what it runs now; one that
    /// ended since is left out.
    func testATreeIsSentAsItsSheetListedIt() throws {
        let root = add(1190, parent: 1101, group: 1190, terminal: tty, foreground: 1101, name: "acme-make")
        let worker = add(1191, parent: 1190, group: 1190, terminal: tty, foreground: 1101, name: "acme-cc")
        let gone = add(1192, parent: 1190, group: 1190, terminal: tty, foreground: 1101, name: "acme-ld")
        let asked = try subject(root)
        kernel.exec(worker.pid, path: "/opt/acme/bin/globex-push", name: "globex-push")
        kernel.remove(gone.pid)
        let fresh = try subject(root)
        XCTAssertEqual(fresh.tree.first?.signal.path, "/opt/acme/bin/globex-push", "the button's read sees the exec")
        let members = ActivityVerbSubject.treeSend(asked: asked, fresh: fresh)
        XCTAssertEqual(members.map(\.identity.pid), [1190, 1191], "the ended one left out")
        XCTAssertEqual(members.last?.path, "/opt/acme/bin/acme-cc", "the executable the sheet listed")
        let signals = ProcessSignals(kernel: kernel, gate: ActivitySignalGate(guards: false), app: ActivityProcessID(pid: 1000, start: 1_000_000), helperGroups: { [] })
        let answers = signals.sendTree(.term, to: members)
        XCTAssertEqual(answers.last?.answer, .ranAnotherProgram(path: "/opt/acme/bin/globex-push"))
        XCTAssertEqual(kernel.sent.map(\.pid), [1190], "only the root: never what 1191 runs now")
    }

    /// A terraform write leading its group, outside the pane's foreground:
    /// SIGINT to its group, asked as an Interrupt.
    func testATerraformWriteLeadingItsGroupIsInterruptedWhole() throws {
        let apply = add(1195, parent: 1101, group: 1195, terminal: tty, foreground: 1101, name: "terraform", argv: ["terraform", "apply"])
        add(1196, parent: 1195, group: 1195, terminal: tty, foreground: 1101, name: "terraform-provider-acme")
        let read = try subject(apply)
        let rule = ActivitySignalCheck.rule(.interrupt, for: read.target, user: 501)
        XCTAssertEqual(rule, .allowed(.signalGroup(.int), confirm: true, critical: false))
        let sheet = try XCTUnwrap(ActivityVerbQuestion.question(.interrupt, rule, subject: read, scope: nil))
        XCTAssertEqual(sheet.title, "Interrupt the process group 1195 of “terraform” (pid 1195) — 2 processes?")
        XCTAssertEqual(sheet.button, "Interrupt Group")
        XCTAssertTrue(sheet.detail.contains("kill -INT -- -1195"), sheet.detail)
    }
}
