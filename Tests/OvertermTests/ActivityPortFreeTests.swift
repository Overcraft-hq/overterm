import Darwin
import XCTest

@testable import Overterm
@testable import OvertermCore

/// The pane pill's Free… over a fake Mac (docs/design/activity/analysis.md,
/// 6.10, 6.12, 10.1): what holds a pill's port is read at the press and
/// classed as the policy sees it, every class a pill can name decided by
/// `ActivitySignalCheck`, and each question's words. Nothing is signalled
/// here: the reads are a fake kernel's.
final class ActivityPortFreeTests: XCTestCase {
    private let tty: dev_t = 0x1000_0007
    private let tag = "pane-a"
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
        _ pid: pid_t, parent: pid_t, uid: uid_t = 501, realUID: uid_t? = nil, group: pid_t? = nil, terminal: dev_t? = nil, ignoredSignals: UInt32 = 0,
        path: String? = nil, name: String, argv: [String]? = nil, environment: [String] = []
    ) -> ActivityProcessID {
        let start = UInt64(pid) * 1_000
        var process = FakeActivityKernel.Process(
            record: FakeActivityKernel.record(
                pid: pid, start: start, parent: parent, uid: uid, realUID: realUID ?? (uid == 0 ? 501 : nil), group: group, terminal: terminal,
                ignoredSignals: ignoredSignals, name: name))
        let executable = path ?? "/opt/acme/bin/\(name)"
        process.name = name
        process.path = executable
        process.arguments = FakeActivityKernel.arguments(executable: executable, argv ?? [name], environment: environment)
        kernel.add(process)
        return ActivityProcessID(pid: pid, start: start)
    }

    private func census() -> ActivitySampler {
        let census = ActivitySampler(kernel: kernel)
        census.appContext = ActivityContext(
            panes: [ActivityContext.Pane(tag: tag, tab: UUID(), login: ActivityProcessID(pid: 1100, start: 1_100_000))], appPID: 1000)
        return census
    }

    /// What a press on the pill naming `identity` finds; `foreground`, the
    /// pane's foreground group as its surface says it.
    private func read(_ identity: ActivityProcessID, foreground: pid_t? = 1101) -> ActivityPortFree.Reading {
        TerminalWindowController.readHolder(identity, login: 1100, tag: tag, foreground: foreground, checkouts: [], census: census())
    }

    private func holder(_ identity: ActivityProcessID, foreground: pid_t? = 1101, file: StaticString = #filePath, line: UInt = #line) throws
        -> ActivityPortFree.Holder
    {
        guard case .holder(let holder) = read(identity, foreground: foreground) else {
            XCTFail("no holder: \(read(identity, foreground: foreground))", file: file, line: line)
            throw XCTSkip()
        }
        return holder
    }

    private func rule(_ holder: ActivityPortFree.Holder) -> ActivityRule { ActivitySignalCheck.rule(.free, for: holder.target, user: 501) }

    private func question(_ holder: ActivityPortFree.Holder, isSplit: Bool = false) -> ActivityPortFree.Question? {
        ActivityPortFree.question(
            rule(holder), holder: holder, port: 3000, scope: "Tab “web” · acme-repo", tabTitle: "web", isSplit: isSplit, timeZone: utc)
    }

    // MARK: Every class a pill can name

    /// The pane's foreground job: Interrupt, ⌃C typed into the pane, asked.
    func testThePanesForegroundJobIsInterrupted() throws {
        let server = add(1102, parent: 1101, group: 1102, terminal: tty, name: "acme-dev", argv: ["acme-dev", "--port", "3000"])
        let found = try holder(server, foreground: 1102)
        XCTAssertEqual(found.target.kind, .paneJob)
        XCTAssertTrue(found.target.inForeground)
        XCTAssertEqual(rule(found), .allowed(.interruptPane, confirm: true, critical: false))
        let asked = try XCTUnwrap(question(found))
        XCTAssertEqual(asked.title, "Interrupt “acme-dev” (pid 1102)?")
        XCTAssertEqual(asked.button, "Interrupt")
        XCTAssertFalse(asked.critical)
        XCTAssertTrue(asked.detail.contains("⌃C is typed into the pane"), asked.detail)
        XCTAssertTrue(asked.detail.contains("Command: acme-dev --port 3000"), asked.detail)
        XCTAssertTrue(asked.detail.contains("Runs /opt/acme/bin/acme-dev"), asked.detail)
        XCTAssertTrue(asked.detail.contains("The command it equals: ⌃C in the pane"), asked.detail)
        XCTAssertEqual(asked.scope, "Tab “web” · acme-repo")
    }

    /// Without the surface's word, the census's own foreground group.
    func testWithoutTheSurfaceTheCensusSaysWhatIsInTheForeground() throws {
        let server = add(1102, parent: 1101, group: 1102, terminal: tty, name: "acme-dev")
        XCTAssertTrue(try holder(server, foreground: nil).target.inForeground, "e_tpgid: its own group's")
    }

    /// Another job of the pane — in the background — is stopped, by its
    /// token: a ⌃C typed would reach the foreground, not it.
    func testABackgroundJobIsStopped() throws {
        let server = add(1102, parent: 1101, group: 1102, terminal: tty, name: "acme-dev")
        add(1103, parent: 1102, group: 1102, terminal: tty, name: "acme-worker")
        let found = try holder(server, foreground: 1101)
        XCTAssertFalse(found.target.inForeground)
        XCTAssertEqual(rule(found), .allowed(.signal(.term), confirm: true, critical: false))
        let asked = try XCTUnwrap(question(found))
        XCTAssertEqual(asked.title, "Stop “acme-dev” (pid 1102)?")
        XCTAssertEqual(asked.button, "Stop Process")
        XCTAssertTrue(asked.detail.contains("Its child keeps running."), asked.detail)
        XCTAssertTrue(asked.detail.contains("The command it equals: kill -TERM 1102"), asked.detail)
        XCTAssertTrue(asked.detail.contains("pid 1102, started 1970-01-01 00:00:01"), asked.detail)
        XCTAssertEqual(found.signal, ActivitySignalTarget(server, path: "/opt/acme/bin/acme-dev"), "by the identity the census listed")
    }

    /// The agent itself: Stop Agent…, critical, saying how to pick it up.
    func testTheAgentIsStopAgent() throws {
        let agent = add(1102, parent: 1101, group: 1102, terminal: tty, name: "claude")
        let found = try holder(agent, foreground: 1102)
        XCTAssertEqual(found.target.kind, .agent)
        XCTAssertEqual(rule(found), .allowed(.signal(.term), confirm: true, critical: true))
        let asked = try XCTUnwrap(question(found))
        XCTAssertEqual(asked.title, "Stop Claude (pid 1102)?")
        XCTAssertEqual(asked.button, "Stop Agent")
        XCTAssertTrue(asked.critical)
        XCTAssertTrue(asked.detail.contains("`claude --continue` picks the conversation up"), asked.detail)
    }

    /// An agent's child in the agent's group, in the foreground: Stop, never
    /// Interrupt — ⌃C would reach the agent too.
    func testAnAgentsChildIsStoppedNeverInterrupted() throws {
        add(1102, parent: 1101, group: 1102, terminal: tty, name: "codex")
        let server = add(1103, parent: 1102, group: 1102, terminal: tty, name: "acme-mcp")
        let found = try holder(server, foreground: 1102)
        XCTAssertEqual(found.target.kind, .agentChild)
        XCTAssertTrue(found.target.groupHoldsAgent)
        XCTAssertEqual(rule(found), .allowed(.signal(.term), confirm: true, critical: false))
    }

    /// A pane job whose group holds an agent by name: never interrupted.
    func testAJobSharingAnAgentsGroupIsStopped() throws {
        add(1102, parent: 1101, group: 1102, terminal: tty, name: "acme-run")
        add(1103, parent: 1102, group: 1102, terminal: tty, path: "/opt/acme/bin/node", name: "node", argv: ["/opt/acme/bin/claude"])
        let server = add(1104, parent: 1102, group: 1102, terminal: tty, name: "acme-dev")
        let found = try holder(server, foreground: 1102)
        XCTAssertTrue(found.target.groupHoldsAgent)
        XCTAssertEqual(rule(found), .allowed(.signal(.term), confirm: true, critical: false))
    }

    /// A terraform write's plugin holds the port: terraform is the one
    /// interrupted — ⌃C typed where it is the pane's foreground job, else
    /// SIGINT to terraform alone. Never SIGTERM.
    func testATerraformWriteIsInterruptedOnly() throws {
        add(1102, parent: 1101, group: 1102, terminal: tty, name: "terraform", argv: ["terraform", "apply", "-auto-approve"])
        let plugin = add(1103, parent: 1102, group: 1102, terminal: tty, name: "terraform-provider-acme")
        let foreground = try holder(plugin, foreground: 1102)
        XCTAssertEqual(foreground.signal.identity.pid, 1102, "terraform, not its plugin")
        XCTAssertEqual(foreground.holder?.pid, 1103)
        XCTAssertEqual(foreground.target.terraformWrite, "terraform apply")
        XCTAssertEqual(rule(foreground), .allowed(.interruptPane, confirm: true, critical: false))
        let asked = try XCTUnwrap(question(foreground))
        XCTAssertTrue(asked.detail.contains("“terraform-provider-acme” (pid 1103)"), asked.detail)
        XCTAssertTrue(asked.detail.contains("could leave its state locked and half written"), asked.detail)

        let background = try holder(plugin, foreground: 1101)
        XCTAssertEqual(rule(background), .allowed(.signal(.int), confirm: true, critical: false))
        XCTAssertTrue(try XCTUnwrap(question(background)).detail.contains("The command it equals: kill -INT 1102"))
    }

    /// One whose argv isn't read yet is a write until it says otherwise.
    func testATerraformNotReadYetIsAWrite() throws {
        var process = FakeActivityKernel.Process(record: FakeActivityKernel.record(pid: 1102, start: 1_102_000, parent: 1101, terminal: tty, name: "terraform"))
        process.name = "terraform"
        process.path = "/opt/acme/bin/terraform"
        kernel.add(process)
        let found = try holder(ActivityProcessID(pid: 1102, start: 1_102_000), foreground: 1101)
        XCTAssertEqual(found.target.terraformWrite, "terraform")
        XCTAssertEqual(rule(found), .allowed(.signal(.int), confirm: true, critical: false))
    }

    /// A terraform plan is no write: its job's verb.
    func testATerraformPlanIsAJob() throws {
        let plan = add(1102, parent: 1101, group: 1102, terminal: tty, name: "terraform", argv: ["terraform", "plan"])
        XCTAssertNil(try holder(plan).target.terraformWrite)
    }

    /// What runs under a helm upgrade: its job's verb, in a critical sheet.
    func testUnderAHelmUpgradeTheSheetIsCritical() throws {
        add(1102, parent: 1101, group: 1102, terminal: tty, name: "helm", argv: ["helm", "upgrade", "acme", "./chart"])
        let child = add(1103, parent: 1102, group: 1102, terminal: tty, name: "acme-plugin")
        let found = try holder(child, foreground: 1101)
        XCTAssertEqual(found.target.releaseWrite, "helm upgrade")
        XCTAssertEqual(rule(found), .allowed(.signal(.term), confirm: true, critical: true))
        XCTAssertTrue(try XCTUnwrap(question(found)).detail.contains("stays pending-upgrade"))
    }

    /// The pane's shell holds it: the close route, asked by Activity.
    func testTheShellIsTheClosePath() throws {
        let shell = ActivityProcessID(pid: 1101, start: 1_101_000)
        let found = try holder(shell)
        XCTAssertEqual(found.target.kind, .paneSession)
        XCTAssertEqual(rule(found), .route(.closePane, confirm: true))
        XCTAssertEqual(question(found)?.title, "Close tab “web”?")
        XCTAssertEqual(question(found)?.button, "Close Tab")
        XCTAssertEqual(question(found, isSplit: true)?.title, "Close this pane?")
        XCTAssertEqual(question(found, isSplit: true)?.button, "Close Pane")
    }

    /// What ignores SIGHUP — nohup'd — or an app started from the pane: no
    /// Free from a pill.
    func testWhatChoseToOutliveItsTerminalAndAnAppAreNotFreedFromAPill() throws {
        let nohup = add(1102, parent: 1101, group: 1102, terminal: tty, ignoredSignals: 1 << UInt32(SIGHUP - 1), name: "acme-dev")
        let found = try holder(nohup)
        XCTAssertTrue(found.target.detached)
        XCTAssertEqual(rule(found), .refused(ActivitySignalCheck.detached))
        XCTAssertNil(question(found), "a refusal asks nothing")

        let tagged = ["\(ProcessInspector.tagVariable)=\(tag)"]
        let app = add(1400, parent: 1, path: "/Applications/Acme Editor.app/Contents/MacOS/Acme Editor", name: "Acme Editor", environment: tagged)
        let helper = add(1401, parent: 1400, name: "acme-helper", environment: tagged)
        XCTAssertEqual(rule(try holder(app)), .refused(ActivitySignalCheck.app))
        XCTAssertEqual(rule(try holder(helper)), .refused(ActivitySignalCheck.app), "under the app")
    }

    /// One that left its terminal, tagged outside the tree: Stop.
    func testWhatLeftItsTerminalIsStopped() throws {
        let tagged = ["\(ProcessInspector.tagVariable)=\(tag)"]
        let left = add(1600, parent: 1, name: "acme-left", environment: tagged)
        let found = try holder(left)
        XCTAssertEqual(found.target.kind, .leftTerminal)
        XCTAssertEqual(rule(found), .allowed(.signal(.term), confirm: true, critical: false))
    }

    /// A setuid program the pane runs: root's here, refused before anything.
    func testASetuidProgramIsRefused() throws {
        let setuid = add(1102, parent: 1101, uid: 0, realUID: 501, group: 1102, terminal: tty, name: "acme-root")
        XCTAssertEqual(rule(try holder(setuid, foreground: 1102)).refusal?.contains("setuid program you started"), true)
    }

    /// Overterm's own helpers: their own route, never a signal from a pill.
    func testOvertermsHelpersAreRefused() throws {
        let helper = add(1200, parent: 1000, name: "acme-helper")
        let found = try holder(helper)
        XCTAssertEqual(found.target.kind, .helper(.other))
        XCTAssertEqual(rule(found), .refused(ActivitySignalCheck.helper))
    }

    /// The pill named a process that ended since — its pid another's now —
    /// or one that runs elsewhere now: nothing to ask.
    func testAnEndedOrMovedHolderAsksNothing() {
        add(1102, parent: 1101, group: 1102, terminal: tty, name: "acme-other")
        XCTAssertEqual(read(ActivityProcessID(pid: 1102, start: 7)), .ended(now: "acme-other"))
        XCTAssertEqual(read(ActivityProcessID(pid: 1999, start: 7)), .ended(now: nil))
        let stranger = add(1700, parent: 1, name: "acme-stranger")
        XCTAssertEqual(read(stranger), .elsewhere)
    }

    // MARK: At the button, and after

    /// ⌃C is typed only while the pane's foreground group is the target's,
    /// and the target the one named (7.10).
    func testATypedInterruptIsCheckedAtTheButton() {
        let listed = ActivityProcessID(pid: 1102, start: 1_102_000)
        let now = FakeActivityKernel.record(pid: 1102, start: 1_102_000, parent: 1101, group: 1102, terminal: tty, name: "acme-dev")
        XCTAssertNil(ActivityPortFree.interruptRefusal(listed: listed, group: 1102, now: now, foregroundGroup: 1102, leader: "acme-dev"))
        XCTAssertEqual(
            ActivityPortFree.interruptRefusal(listed: listed, group: 1102, now: now, foregroundGroup: 1300, leader: "git"),
            "The pane now runs “git”: nothing was typed.")
        XCTAssertEqual(
            ActivityPortFree.interruptRefusal(listed: listed, group: 1102, now: now, foregroundGroup: nil, leader: nil),
            "It is no longer the pane's foreground job: nothing was typed.")
        let reused = FakeActivityKernel.record(pid: 1102, start: 9_000_000, parent: 1101, group: 1102, terminal: tty, name: "acme-new")
        XCTAssertEqual(
            ActivityPortFree.interruptRefusal(listed: listed, group: 1102, now: reused, foregroundGroup: 1102, leader: "acme-new"),
            "It ended before ⌃C was typed: nothing was sent.")
        XCTAssertNotNil(ActivityPortFree.interruptRefusal(listed: listed, group: 1102, now: nil, foregroundGroup: 1102, leader: nil))
    }

    /// What a send that didn't go says.
    func testWhatASendThatDidntGoSays() {
        XCTAssertNil(ActivityPortFree.answer(.sent(pinned: true), pid: 4242))
        XCTAssertEqual(ActivityPortFree.answer(.ended(now: "acme-x"), pid: 4242), "It ended — pid 4242 is now “acme-x”. Nothing was sent.")
        XCTAssertEqual(ActivityPortFree.answer(.ended(now: nil), pid: 4242), "It ended. Nothing was sent.")
        XCTAssertTrue(ActivityPortFree.answer(.ranAnotherProgram(path: "/opt/acme/bin/acme-y"), pid: 4242)?.contains("It became “acme-y”") == true)
        XCTAssertEqual(ActivityPortFree.answer(.refused(.gate), pid: 4242), ActivitySignalRefusal.gate.reason)
        XCTAssertEqual(ActivityPortFree.answer(.failed(EPERM), pid: 4242), "macOS refused the signal: Operation not permitted.")
    }

    /// The watch after a Free: free, came back as another, or still held.
    func testTheWatchSaysWhenThePortIsFree() {
        let freed = ActivityProcessID(pid: 4242, start: 1)
        let sentAt: UInt64 = 1_000
        XCTAssertEqual(PortFreeing.state(holders: [], freed: freed, sentAt: sentAt, final: false), .free)
        XCTAssertEqual(PortFreeing.state(holders: [freed], freed: freed, sentAt: sentAt, final: false), .freeing)
        XCTAssertEqual(PortFreeing.state(holders: [freed], freed: freed, sentAt: sentAt, final: true), .stillHeld(pid: 4242))
        let started = ActivityProcessID(pid: 4300, start: 2_000)
        XCTAssertEqual(PortFreeing.state(holders: [started], freed: freed, sentAt: sentAt, final: false), .cameBack(pid: 4300))
        let pane = ObjectIdentifier(self)
        XCTAssertEqual(PortFreeing(pane: pane, port: 3000, proto: "tcp", state: .free).label, ":3000 is free")
        XCTAssertEqual(PortFreeing(pane: pane, port: 3000, proto: "tcp", state: .cameBack(pid: 4300)).label, ":3000 came back as pid 4300")
        XCTAssertEqual(PortFreeing(pane: pane, port: 3000, proto: "tcp", state: .stillHeld(pid: 4242)).label, ":3000 still held — pid 4242")
        XCTAssertEqual(PortFreeing(pane: pane, port: 3000, proto: "tcp", state: .stillHeld(pid: nil)).label, ":3000 still held")
    }

    /// Terraform interrupted, its plugin on the port: the watch follows the
    /// plugin the pill listed, not terraform, so the plugin still there is
    /// still freeing — never "came back" — until it lets go.
    func testTheWatchFollowsThePortsHolderUnderTerraform() throws {
        add(1102, parent: 1101, group: 1102, terminal: tty, name: "terraform", argv: ["terraform", "apply"])
        let plugin = add(1103, parent: 1102, group: 1102, terminal: tty, name: "terraform-provider-acme")
        let found = try holder(plugin, foreground: 1102)
        XCTAssertNotEqual(found.signal.identity, plugin, "terraform is the one signalled")
        let sentAt: UInt64 = 5_000_000
        XCTAssertEqual(PortFreeing.state(holders: [plugin], freed: plugin, sentAt: sentAt, final: false), .freeing)
        XCTAssertEqual(PortFreeing.state(holders: [plugin], freed: plugin, sentAt: sentAt, final: true), .stillHeld(pid: 1103))
        XCTAssertEqual(PortFreeing.state(holders: [], freed: plugin, sentAt: sentAt, final: false), .free)
    }

    /// What held the socket before the Free beside the one freed — a
    /// pre-fork server's workers, a child that inherited it — didn't come
    /// back: it is waited for, then named as what still holds it. Only a process
    /// started since the Free came back.
    func testOnlyAProcessStartedSinceTheFreeCameBack() {
        let freed = ActivityProcessID(pid: 4242, start: 1_000)
        let worker = ActivityProcessID(pid: 4243, start: 1_500)
        let sentAt: UInt64 = 9_000
        XCTAssertEqual(PortFreeing.state(holders: [worker], freed: freed, sentAt: sentAt, final: false), .freeing)
        XCTAssertEqual(PortFreeing.state(holders: [worker], freed: freed, sentAt: sentAt, final: true), .inherited(pid: 4243))
        XCTAssertEqual(PortFreeing.label(.inherited(pid: 4243), port: 3000), ":3000 still held by pid 4243, which held it with the one freed")
        let new = ActivityProcessID(pid: 4400, start: 9_500)
        XCTAssertEqual(PortFreeing.state(holders: [worker, new], freed: freed, sentAt: sentAt, final: false), .cameBack(pid: 4400))
        // A container's or a forward's port names no process: free or held.
        XCTAssertEqual(PortFreeing.state(holders: [], freed: nil, sentAt: sentAt, final: false), .free)
        XCTAssertEqual(PortFreeing.state(holders: [worker], freed: nil, sentAt: sentAt, final: false), .freeing)
        XCTAssertEqual(PortFreeing.state(holders: [worker], freed: nil, sentAt: sentAt, final: true), .stillHeld(pid: 4243))
    }

    /// The button asks the policy again of what holds the port now
    /// (6.10 step 4): a background job moved to the foreground while the
    /// sheet was up is refused, not sent the Stop it was asked about; one
    /// that ended or left asks again too; the same one, the same rule, goes.
    func testTheButtonAsksThePolicyAgain() throws {
        let server = add(1102, parent: 1101, group: 1102, terminal: tty, name: "acme-dev")
        let asked = try holder(server, foreground: 1101)
        let stop = rule(asked)
        XCTAssertEqual(stop, .allowed(.signal(.term), confirm: true, critical: false))
        XCTAssertNil(ActivityPortFree.changedAtButton(asked: asked, rule: stop, now: read(server, foreground: 1101), port: 3000, user: 501))
        let moved = try XCTUnwrap(ActivityPortFree.changedAtButton(asked: asked, rule: stop, now: read(server, foreground: 1102), port: 3000, user: 501))
        XCTAssertTrue(moved.contains("changed while you were asked"), moved)
        let gone = try XCTUnwrap(ActivityPortFree.changedAtButton(asked: asked, rule: stop, now: .ended(now: nil), port: 3000, user: 501))
        XCTAssertTrue(gone.contains("nothing was sent"), gone)
    }

    /// A pane not paired yet reads by its tag alone: what the press does
    /// rather than read the whole table on the main thread (7.7).
    func testAPaneNotPairedYetIsReadByItsTag() throws {
        let server = add(1102, parent: 1101, group: 1102, terminal: tty, name: "acme-dev")
        let byTag = TerminalWindowController.readHolder(server, login: nil, tag: tag, foreground: 1101, checkouts: [], census: census())
        XCTAssertEqual(byTag, read(server, foreground: 1101))
    }

    /// Overterm's helpers have their own routes (6.10's table), which stage
    /// 0's pill doesn't take: every one is refused with why, and asks
    /// nothing (analysis.md 15, the pill).
    func testAHelperAsksNothing() throws {
        let helper = add(1200, parent: 1000, name: "acme-helper")
        let found = try holder(helper)
        XCTAssertNil(question(found))
        XCTAssertEqual(ActivityPortFree.refusal(ActivitySignalCheck.helper, port: 3000).detail, ActivitySignalCheck.helper)
    }

    // MARK: The owners' own Stop, now asked

    /// A container's Stop and a forward's: asked first, saying what they equal.
    func testAContainersAndAForwardsStopAreAsked() {
        let container = ActivityPortFree.containerQuestion("acme-web-1", port: 58080)
        XCTAssertEqual(container.title, "Stop container “acme-web-1”?")
        XCTAssertEqual(container.button, "Stop Container")
        XCTAssertTrue(container.detail.contains("docker stop acme-web-1"))
        let forward = KubeForwardPill(
            id: UUID(), context: "fake-prod", namespace: "shop", target: "svc/web", pod: "web-1", https: false, forwarding: true, production: true,
            state: "forwarding")
        let asked = ActivityPortFree.forwardQuestion(forward, port: 31083)
        XCTAssertEqual(asked.title, "Stop the forward to svc/web?")
        XCTAssertEqual(asked.button, "Stop Forward")
        XCTAssertTrue(asked.production)
        XCTAssertEqual(asked.scope, "PRODUCTION · fake-prod · namespace shop")
        XCTAssertTrue(asked.detail.contains(":31083"))
    }

    /// Every character visible: a name can carry a newline or a direction
    /// override (`DockerMCP.displayed`).
    func testANamesHiddenCharactersAreShown() throws {
        let odd = add(1102, parent: 1101, group: 1102, terminal: tty, name: "acme\u{202E}ved", argv: ["acme\u{202E}ved"])
        let asked = try XCTUnwrap(question(try holder(odd, foreground: 1101)))
        XCTAssertFalse(asked.title.contains("\u{202E}"), asked.title)
    }
}
