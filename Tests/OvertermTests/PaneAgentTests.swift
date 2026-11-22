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
@testable import OvertermSimulator
@testable import OvertermUsage
@testable import OvertermSettingsPage
@testable import OvertermAgents
@testable import OvertermActivity

/// A tab's agent from a fake census (docs/design/activity/analysis.md,
/// 7.8): the readers that walked every pane's tree with a scan of their own
/// — the overview, Sessions, an MCP confirmation — look it up in one
/// snapshot. Names are invented; nothing of this Mac is read.
final class PaneAgentTests: XCTestCase {
    private let kernel = FakeActivityKernel(uid: 501)
    private let app: pid_t = 1000
    private let tab = UUID()
    private let other = UUID()

    @discardableResult
    private func add(
        _ pid: pid_t, parent: pid_t, uid: uid_t = 501, status: Int32 = SRUN, name: String, words: [String]? = nil, folder: String? = nil,
        environment: [String] = []
    ) -> ActivityProcessID {
        let start = UInt64(pid) * 1_000
        let path = "/opt/acme/bin/\(name)"
        var process = FakeActivityKernel.Process(
            record: FakeActivityKernel.record(
                pid: pid, start: start, parent: parent, uid: uid, realUID: uid == 0 ? 501 : nil, status: status, name: name))
        process.name = name
        process.path = path
        process.codeSigning = ActivityCodeSigning(flags: ActivityCodeSigning.valid)
        process.usage = FakeActivityKernel.usage()
        process.arguments = FakeActivityKernel.arguments(executable: path, words ?? [name], environment: environment)
        process.folder = folder
        kernel.add(process)
        return ActivityProcessID(pid: pid, start: start)
    }

    /// A pane: its root-owned `login` under the app, a shell under it.
    private func pane(_ tag: String, login: pid_t, tab: UUID) -> ActivityContext.Pane {
        let identity = add(login, parent: app, uid: 0, name: "login")
        add(login + 1, parent: login, name: "zsh")
        return ActivityContext.Pane(tag: tag, tab: tab, login: identity)
    }

    private func census(_ panes: [ActivityContext.Pane]) -> ActivitySampler {
        add(1, parent: 0, uid: 0, name: "launchd")
        add(app, parent: 1, name: "Overterm")
        let sampler = ActivitySampler(kernel: kernel)
        sampler.appContext = ActivityContext(panes: panes, appPID: app)
        return sampler
    }

    /// Every tab's agent from one snapshot: two tabs of two panes each, one
    /// tick for all of them — the overview's tabs × panes scans gone —, and
    /// none again while it is fresh. The first agent in the panes' order,
    /// its kind, its masked command and its folder; a tab with none has
    /// none.
    func testEveryTabsAgentFromOneSnapshot() throws {
        let panes = [
            pane("pane-a1", login: 1100, tab: tab), pane("pane-a2", login: 1200, tab: tab),
            pane("pane-b1", login: 1300, tab: other), pane("pane-b2", login: 1400, tab: other),
        ]
        let claude = add(1202, parent: 1201, name: "node", words: ["claude", "--resume", "acme-session"], folder: "/tmp/acme-checkout")
        let sampler = census(panes)
        let tabs = [(id: tab, tags: ["pane-a1", "pane-a2"]), (id: other, tags: ["pane-b1", "pane-b2"])]
        let found = PaneAgent.lookup(tabs, census: sampler, folders: true)
        XCTAssertEqual(found[tab]?.identity, claude)
        XCTAssertEqual(found[tab]?.kind, .claude, "by argv[0]")
        XCTAssertEqual(found[tab]?.command, "claude --resume acme-session")
        XCTAssertEqual(found[tab]?.folder, "/tmp/acme-checkout", "waited for")
        XCTAssertNil(found[other])
        let ticks = try XCTUnwrap(sampler.latest).tick
        let tables = kernel.count("processes")
        _ = PaneAgent.lookup(tabs, census: sampler, folders: true)
        _ = PaneAgent.lookup([(id: other, tags: ["pane-b2"])], census: sampler, folders: false)
        XCTAssertEqual(sampler.latest?.tick, ticks, "a fresh snapshot answers: no tick")
        XCTAssertEqual(kernel.count("processes"), tables, "no table read")
    }

    /// The panes' order decides; a pane the snapshot has for another tab
    /// isn't this tab's; an agent that has ended (a zombie) isn't running.
    func testTheFirstRunningAgentInThePanesOrder() throws {
        let panes = [pane("pane-a1", login: 1100, tab: tab), pane("pane-a2", login: 1200, tab: tab)]
        add(1102, parent: 1101, status: SZOMB, name: "claude")
        let codex = add(1202, parent: 1201, name: "codex")
        let sampler = census(panes)
        let demand = ActivityDemand(.light(tabs: [tab]))
        let snapshot = try XCTUnwrap(sampler.tickNow(demand, context: sampler.appContext))
        XCTAssertEqual(PaneAgent.first(["pane-a1", "pane-a2"], tab: tab, in: snapshot)?.identity, codex, "the zombie claude has ended")
        XCTAssertEqual(PaneAgent.first(["pane-a2"], tab: tab, in: snapshot)?.kind, .codex)
        XCTAssertNil(PaneAgent.first(["pane-a2"], tab: other, in: snapshot), "another tab's pane")
        XCTAssertNil(PaneAgent.first(["pane-a1"], tab: tab, in: snapshot))
    }

    /// An agent carrying the pane's tag outside its tree — a `claude` in a
    /// tmux session started there, one nohup'd or setsid'd out — is the
    /// pane's agent for these readers, as the scans they made found one by
    /// tag: they only display it (6.5's `placed`).
    func testAnAgentTaggedOutsideTheTreeIsFound() throws {
        let panes = [pane("pane-a1", login: 1100, tab: tab)]
        let tmux = add(4000, parent: 1, name: "tmux", words: ["tmux", "new"], environment: ["OVERTERM_TAB_ID=pane-a1"])
        let claude = add(4001, parent: 4000, name: "claude", folder: "/tmp/acme-tmux", environment: ["OVERTERM_TAB_ID=pane-a1"])
        let sampler = census(panes)
        let found = PaneAgent.lookup([(id: tab, tags: ["pane-a1"])], census: sampler, folders: true)
        XCTAssertEqual(found[tab]?.identity, claude, "found by its tag")
        XCTAssertEqual(found[tab]?.folder, "/tmp/acme-tmux")
        let snapshot = try XCTUnwrap(sampler.latest)
        XCTAssertEqual(snapshot.pane("pane-a1")?.tagged.first, tmux, "outside the tree")
        XCTAssertNil(snapshot.pane("pane-a1")?.agent, "the light tick's agent is its tree's alone")
    }

    /// Codex and Claude in one pane: the first agent is the one that comes
    /// first; Sessions' Claude is found past it, in the same pane. A zombie
    /// first agent hides no live one after it.
    func testCodexAndClaudeInOnePane() throws {
        let panes = [pane("pane-a1", login: 1100, tab: tab)]
        add(1102, parent: 1101, status: SZOMB, name: "claude")
        let codex = add(1103, parent: 1101, name: "codex")
        let claude = add(1104, parent: 1101, name: "node", words: ["claude", "--resume", "acme-session"], folder: "/tmp/acme-checkout")
        let sampler = census(panes)
        let tabs = [(id: tab, tags: ["pane-a1"])]
        XCTAssertEqual(PaneAgent.lookup(tabs, census: sampler, folders: false)[tab]?.identity, codex, "the zombie has ended")
        let claudes = PaneAgent.lookup(tabs, census: sampler, only: .claude, folders: true)
        XCTAssertEqual(claudes[tab]?.identity, claude, "past the Codex before it")
        XCTAssertEqual(SessionsModel.claudes([tab], claudes).first?.directory, "/tmp/acme-checkout")
    }

    /// A card says the agent the census found, where it works, and that it
    /// runs; with none running, the agent the tab was opened for, not
    /// running, where the tab works.
    func testACardFromTheAgentFound() {
        let snapshot = AgentOverviewModel.Snapshot(
            id: tab, title: "acme", color: nil, agent: nil, activity: TabActivity(), directory: "/tmp/fake-elsewhere", tags: ["pane-a1"],
            panes: 1)
        let running = PaneAgent(identity: ActivityProcessID(pid: 1202, start: 1), kind: .codex, command: "codex", folder: "/tmp/fake-acme")
        let card = AgentOverviewModel.card(for: snapshot, agent: running)
        XCTAssertEqual(card.agent, .codex)
        XCTAssertTrue(card.agentRunning)
        XCTAssertEqual(card.directory, "/tmp/fake-acme")
        XCTAssertEqual(card.agentProcess, ActivityProcessID(pid: 1202, start: 1), "Show in Activity selects it (6.12)")
        let opened = AgentOverviewModel.Snapshot(
            id: tab, title: "acme", color: nil, agent: .codex, activity: TabActivity(), directory: "/tmp/fake-elsewhere", tags: [],
            panes: 1)
        let idle = AgentOverviewModel.card(for: opened, agent: nil)
        XCTAssertEqual(idle.agent, .codex)
        XCTAssertFalse(idle.agentRunning)
        XCTAssertEqual(idle.directory, "/tmp/fake-elsewhere")
        XCTAssertNil(idle.agentProcess, "none running: the link shows the tab")
    }

    /// A card's agent's numbers (6.12): it and everything under it, from
    /// the census's snapshot — CPU none before a second sample, the
    /// footprints summed, its server's port — no scan of the overview's.
    func testACardSaysWhatItsAgentSpends() throws {
        let panes = [pane("pane-a1", login: 1100, tab: tab)]
        let agent = add(1102, parent: 1101, name: "node", words: ["claude"])
        var server = FakeActivityKernel.Process(record: FakeActivityKernel.record(pid: 1103, start: 1_103_000, parent: 1102, uid: 501, name: "acme-dev"))
        server.name = "acme-dev"
        server.path = "/opt/acme/bin/acme-dev"
        server.usage = FakeActivityKernel.usage(footprint: 48 << 20)
        server.descriptors = [FakeActivityKernel.descriptor(3)]
        server.sockets = [3: FakeActivityKernel.tcp(local: "127.0.0.1", port: 5179, handle: 1103)]
        kernel.add(server)
        let sampler = census(panes)
        let snapshot = try XCTUnwrap(sampler.tickNow(ActivityDemand(.light(tabs: [tab])), context: sampler.appContext))
        let usage = try XCTUnwrap(AgentOverviewModel.usage(of: agent, in: snapshot))
        XCTAssertNil(usage.cpu, "no rate before a second sample, never 0")
        XCTAssertEqual(usage.footprint, 48 << 20, "it and what it started")
        XCTAssertEqual(usage.servers.map(\.port), [5179])
        XCTAssertNil(AgentOverviewModel.usage(of: ActivityProcessID(pid: 4999, start: 1), in: snapshot), "gone: nothing said")
        let card = AgentOverviewModel.card(
            for: AgentOverviewModel.Snapshot(
                id: tab, title: "acme", color: nil, agent: nil, activity: TabActivity(), directory: nil, tags: ["pane-a1"], panes: 1),
            agent: PaneAgent(identity: agent, kind: .claude, command: "claude", folder: nil), snapshot: snapshot)
        XCTAssertEqual(card.usage, usage)
    }

    /// Sessions' Claude: the first Claude, past a Codex in an earlier pane,
    /// with the session it resumed — read off argv's raw words, where the
    /// masked command loses the `-r` of `--fork-session -r <id>` — and its
    /// folder; a tab running only Codex runs no Claude session.
    func testSessionsTakeTheTabsClaude() {
        let panes = [
            pane("pane-a1", login: 1100, tab: tab), pane("pane-a2", login: 1200, tab: tab), pane("pane-b1", login: 1300, tab: other),
        ]
        add(1102, parent: 1101, name: "codex", folder: "/tmp/acme-codex")
        let id = "acde0123-4567-89ab-cdef-0123456789ab"
        add(1202, parent: 1201, name: "node", words: ["claude", "--fork-session", "-r", id], folder: "/tmp/acme-checkout")
        add(1302, parent: 1301, name: "codex", folder: "/tmp/acme-other")
        let sampler = census(panes)
        let tabs = [(id: tab, tags: ["pane-a1", "pane-a2"]), (id: other, tags: ["pane-b1"])]
        let agents = PaneAgent.lookup(tabs, census: sampler, only: .claude, folders: true)
        let claudes = SessionsModel.claudes([tab, other], agents)
        XCTAssertEqual(claudes.map(\.tab), [tab], "only Codex runs in the other")
        XCTAssertEqual(claudes.first?.directory, "/tmp/acme-checkout")
        XCTAssertEqual(claudes.first?.resumes, id)
        XCTAssertEqual(PaneAgent.lookup(tabs, census: sampler, folders: false)[tab]?.kind, .codex, "the first agent, of any kind")
    }

    /// An MCP confirmation from an agent typed into a plain tab names it
    /// from the census: its pane's slice, read off the main thread — the
    /// table read on a GCD thread, never the main one — and once fresh,
    /// from that snapshot with nothing read again. No environment is read
    /// for it beyond the markers the census reads once per process.
    @MainActor
    func testAnMCPConfirmationNamesItsAgentFromTheCensusOffMain() async throws {
        let panes = [pane("pane-a1", login: 1100, tab: tab), pane("pane-b1", login: 1300, tab: other)]
        add(1102, parent: 1101, name: "codex")
        let sampler = census(panes)
        let onMain = ThreadRecord()
        kernel.onCall { call in if call == "processes" { onMain.add(Thread.isMainThread) } }
        let named = await MCPAsker.agent(tab: tab, pane: "pane-a1", census: sampler)
        XCTAssertEqual(named, "Codex")
        XCTAssertFalse(onMain.values.isEmpty, "the table was read for it")
        XCTAssertFalse(onMain.values.contains(true), "never on the main thread")
        let tables = kernel.count("processes")
        let arguments = kernel.count("arguments")
        let again = await MCPAsker.agent(tab: tab, pane: "pane-a1", census: sampler)
        XCTAssertEqual(again, "Codex")
        XCTAssertEqual(kernel.count("processes"), tables, "the fresh snapshot answered")
        XCTAssertEqual(kernel.count("arguments"), arguments, "no argv or environment read again")
        let none = await MCPAsker.agent(tab: other, pane: "pane-b1", census: sampler)
        XCTAssertNil(none, "a shell: no agent")
        let elsewhere = await MCPAsker.agent(tab: other, pane: "pane-a1", census: sampler)
        XCTAssertNil(elsewhere, "the pane isn't that tab's")
        kernel.onCall(nil)
    }

    /// A pane whose `login` isn't paired yet — a pane made while no window
    /// showed, no light tick to pair it — reads empty; an MCP confirmation
    /// from it pairs its surface from the lookup's own snapshot (the app's
    /// children and the `login`s no pane claimed), on the main actor, and
    /// looks again: it names its agent, and the snapshot made before the
    /// pairing is no answer once it is made.
    @MainActor
    func testAPaneNotPairedYetIsPairedFromTheLookupsSnapshot() async throws {
        add(1, parent: 0, uid: 0, name: "launchd")
        add(app, parent: 1, name: "Overterm")
        let login = add(1100, parent: app, uid: 0, name: "login")
        add(1101, parent: 1100, name: "zsh")
        add(1102, parent: 1101, name: "codex")
        let sampler = ActivitySampler(kernel: kernel)
        let monitor = ActivityMonitor(sampler: sampler)
        let surfaces = SurfaceProcesses(monitor: monitor)
        let surface = StandIn()
        surfaces.register(surface, at: 0)
        let tab = self.tab
        let app = self.app
        monitor.contextSource = {
            ActivityContext(panes: [ActivityContext.Pane(tag: "pane-a1", tab: tab, login: surfaces.login(of: surface))], appPID: app)
        }
        monitor.contextChanged()
        monitor.flushContext()
        XCTAssertNil(sampler.appContext.panes.first?.login, "waiting for its login")
        XCTAssertNil(PaneAgent.lookup([(id: tab, tags: ["pane-a1"])], census: sampler, folders: false)[tab], "no login, no tree")
        let tables = kernel.count("processes")
        let named = await MCPAsker.agent(tab: tab, pane: "pane-a1", census: sampler, surfaces: surfaces, monitor: monitor)
        XCTAssertEqual(named, "Codex")
        XCTAssertEqual(surfaces.login(of: surface), login, "paired from the snapshot")
        XCTAssertEqual(sampler.appContext.panes.first?.login, login, "the context rebuilt")
        XCTAssertEqual(kernel.count("processes"), tables + 1, "the fresh snapshot paired it; one tick read the pane again")
        XCTAssertEqual(
            PaneAgent.lookup([(id: tab, tags: ["pane-a1"])], census: sampler, folders: false)[tab]?.kind, .codex, "and the next lookup sees it")
    }

    /// The screen check's agent (`TerminalWindowController.foregroundAgent`)
    /// is a lookup in the census, no walk of its own: the pane's terminal's
    /// foreground group as the table read it, and the first agent in it —
    /// Gemini CLI under `node` by its script; an agent in the background of
    /// its pane isn't the one asking.
    func testTheForegroundAgentFromTheCensus() throws {
        func record(_ pid: pid_t, parent: pid_t, uid: uid_t = 501, group: pid_t, foreground: pid_t, name: String, words: [String]) {
            let path = "/opt/acme/bin/\(name)"
            var process = FakeActivityKernel.Process(
                record: ActivityProcess(
                    identity: ActivityProcessID(pid: pid, start: UInt64(pid) * 1_000), parentPID: parent, group: group, terminal: 7,
                    terminalGroup: foreground, effectiveUID: uid, realUID: uid == 0 ? 501 : uid, savedUID: uid, status: SRUN, flags: [],
                    ignoredSignals: 0, caughtSignals: 0, nice: 0, shortName: name))
            process.name = name
            process.path = path
            process.codeSigning = ActivityCodeSigning(flags: ActivityCodeSigning.valid)
            process.usage = FakeActivityKernel.usage()
            process.arguments = FakeActivityKernel.arguments(executable: path, words)
            kernel.add(process)
        }
        record(1100, parent: app, uid: 0, group: 1100, foreground: 1102, name: "login", words: ["login"])
        record(1101, parent: 1100, group: 1101, foreground: 1102, name: "zsh", words: ["-zsh"])
        record(1103, parent: 1101, group: 1103, foreground: 1102, name: "codex", words: ["codex"])
        record(1102, parent: 1101, group: 1102, foreground: 1102, name: "node", words: ["node", "/opt/homebrew/bin/gemini"])
        let login = ActivityProcessID(pid: 1100, start: 1_100_000)
        let sampler = census([ActivityContext.Pane(tag: "pane-a1", tab: tab, login: login)])
        let snapshot = try XCTUnwrap(sampler.tickNow(ActivityDemand(.light(tabs: [tab])), context: sampler.appContext))
        let slice = try XCTUnwrap(snapshot.pane("pane-a1"))
        XCTAssertEqual(TerminalWindowController.foregroundAgent(in: slice, snapshot: snapshot), .gemini, "the foreground's, not the Codex behind it")
        let ticks = try XCTUnwrap(sampler.latest).tick
        let inspector = ProcessInspector(census: sampler)
        XCTAssertEqual(TerminalWindowController.foregroundAgent(login: 1100, tag: "pane-a1", inspector: inspector), .gemini)
        XCTAssertEqual(sampler.latest?.tick, ticks, "a fresh snapshot answers: no tick")
    }
}

/// A surface a unit test has: alive, never ghostty's.
@MainActor private final class StandIn: PairedSurface {
    var hasSurface: Bool { true }
}

/// Values recorded from any thread.
private final class ThreadRecord: @unchecked Sendable {
    private let lock = NSLock()
    private var recorded: [Bool] = []
    func add(_ value: Bool) { lock.withLock { recorded.append(value) } }
    var values: [Bool] { lock.withLock { recorded } }
}
