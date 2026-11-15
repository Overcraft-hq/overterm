import Darwin
import Foundation
import XCTest

@testable import Overterm

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
        _ pid: pid_t, parent: pid_t, uid: uid_t = 501, status: Int32 = SRUN, name: String, words: [String]? = nil, folder: String? = nil
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
        process.arguments = FakeActivityKernel.arguments(executable: path, words ?? [name])
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
        let opened = AgentOverviewModel.Snapshot(
            id: tab, title: "acme", color: nil, agent: .codex, activity: TabActivity(), directory: "/tmp/fake-elsewhere", tags: [],
            panes: 1)
        let idle = AgentOverviewModel.card(for: opened, agent: nil)
        XCTAssertEqual(idle.agent, .codex)
        XCTAssertFalse(idle.agentRunning)
        XCTAssertEqual(idle.directory, "/tmp/fake-elsewhere")
    }

    /// Sessions' Claude: the first Claude, past a Codex in an earlier pane,
    /// with its masked command — what says which session it resumed — and
    /// its folder; a tab running only Codex runs no Claude session.
    func testSessionsTakeTheTabsClaude() {
        let panes = [
            pane("pane-a1", login: 1100, tab: tab), pane("pane-a2", login: 1200, tab: tab), pane("pane-b1", login: 1300, tab: other),
        ]
        add(1102, parent: 1101, name: "codex", folder: "/tmp/acme-codex")
        add(1202, parent: 1201, name: "node", words: ["claude", "--resume", "acme-session"], folder: "/tmp/acme-checkout")
        add(1302, parent: 1301, name: "codex", folder: "/tmp/acme-other")
        let sampler = census(panes)
        let tabs = [(id: tab, tags: ["pane-a1", "pane-a2"]), (id: other, tags: ["pane-b1"])]
        let agents = PaneAgent.lookup(tabs, census: sampler, only: .claude, folders: true)
        let claudes = SessionsModel.claudes([tab, other], agents)
        XCTAssertEqual(claudes.map(\.tab), [tab], "only Codex runs in the other")
        XCTAssertEqual(claudes.first?.directory, "/tmp/acme-checkout")
        XCTAssertEqual(claudes.first?.command, "claude --resume acme-session")
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
}

/// Values recorded from any thread.
private final class ThreadRecord: @unchecked Sendable {
    private let lock = NSLock()
    private var recorded: [Bool] = []
    func add(_ value: Bool) { lock.withLock { recorded.append(value) } }
    var values: [Bool] { lock.withLock { recorded } }
}
