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

/// The light tick's consumers from a fake census (docs/design/activity/
/// analysis.md, 7.8's agent-poll row): what a tab's panes listen on, each
/// pane's own — a nohup'd server carrying a pane's tag under that pane —,
/// a holder's sockets on one port once, the focused pane's agent first and
/// its folder followed, kept while it isn't read yet, nothing to follow
/// where it can't be; a pane the snapshot has for another tab isn't this
/// tab's. Tabs are real and surfaceless in unit tests, so the window's own
/// step — setting these on the tabs — is the E2E scenarios'.
final class TabLightReadTests: XCTestCase {
    private let kernel = FakeActivityKernel(uid: 501)
    private let app: pid_t = 1000
    private let tab = UUID()
    private let other = UUID()

    @discardableResult
    private func add(
        _ pid: pid_t, parent: pid_t, uid: uid_t = 501, savedUID: uid_t? = nil, name: String, environment: [String] = [], folder: String? = nil,
        sockets: [socket_fdinfo] = []
    ) -> ActivityProcessID {
        let start = UInt64(pid) * 1_000
        let path = "/opt/acme/bin/\(name)"
        var process = FakeActivityKernel.Process(
            record: FakeActivityKernel.record(
                pid: pid, start: start, parent: parent, uid: uid, realUID: uid == 0 ? 501 : nil, savedUID: savedUID, name: name))
        process.name = name
        process.path = path
        process.codeSigning = ActivityCodeSigning(flags: ActivityCodeSigning.valid)
        process.usage = FakeActivityKernel.usage()
        process.arguments = FakeActivityKernel.arguments(executable: path, [name], environment: environment)
        process.folder = folder
        process.descriptors = sockets.indices.map { FakeActivityKernel.descriptor(Int32($0 + 3)) }
        process.sockets = Dictionary(uniqueKeysWithValues: sockets.enumerated().map { (Int32($0 + 3), $1) })
        kernel.add(process)
        return ActivityProcessID(pid: pid, start: start)
    }

    /// A pane: its root-owned `login` under the app, a shell under it.
    private func pane(_ tag: String, login: pid_t, tab: UUID) -> ActivityContext.Pane {
        let identity = add(login, parent: app, uid: 0, name: "login")
        add(login + 1, parent: login, name: "zsh")
        return ActivityContext.Pane(tag: tag, tab: tab, login: identity)
    }

    private func appAndLaunchd() {
        add(1, parent: 0, uid: 0, name: "launchd")
        add(app, parent: 1, name: "Overterm")
    }

    private func tick(_ sampler: ActivitySampler, _ panes: [ActivityContext.Pane], tabs: Set<UUID>) throws -> ActivitySnapshot {
        try XCTUnwrap(sampler.tickNow(ActivityDemand(.light(tabs: tabs)), context: ActivityContext(panes: panes, appPID: app)))
    }

    /// Each pane says its own: its tree's listeners, and what carries its
    /// tag outside its tree (a nohup'd server, reparented to launchd); a
    /// process's v4 and v6 sockets on one port once; the tab's ports all
    /// of them, sorted. Another tab's server is never this tab's.
    func testEachPaneSaysItsOwnPorts() throws {
        typealias K = FakeActivityKernel
        appAndLaunchd()
        let left = pane("pane-left", login: 1100, tab: tab)
        add(1102, parent: 1101, name: "acme-vite", sockets: [K.tcp(local: "127.0.0.1", port: 5173), K.tcp(local: "::1", port: 5173, handle: 2)])
        let right = pane("pane-right", login: 1200, tab: tab)
        add(1202, parent: 1201, name: "acme-api", sockets: [K.tcp(local: "0.0.0.0", port: 8000, handle: 3)])
        add(1300, parent: 1, name: "acme-worker", environment: ["OVERTERM_TAB_ID=pane-right"], sockets: [K.tcp(local: "127.0.0.1", port: 9000, handle: 4)])
        let elsewhere = pane("pane-other", login: 1400, tab: other)
        add(1402, parent: 1401, name: "acme-web", sockets: [K.tcp(local: "127.0.0.1", port: 3000, handle: 5)])

        let snapshot = try tick(ActivitySampler(kernel: kernel), [left, right, elsewhere], tabs: [tab])
        let read = TabLightRead.of(["pane-left", "pane-right"], tab: tab, in: snapshot)
        XCTAssertEqual(read.ports.map(\.port), [5173, 8000, 9000])
        XCTAssertEqual(read.panePorts[0]?.map(\.port), [5173])
        XCTAssertEqual(read.panePorts[1]?.map(\.port), [8000, 9000], "the nohup'd server is its pane's")
        XCTAssertEqual(read.ports.first?.families, [.v4, .v6], "one pill for both families")
        XCTAssertEqual(read.ports.map { $0.url?.absoluteString }, ["http://localhost:5173", "http://127.0.0.1:8000", "http://127.0.0.1:9000"])
        XCTAssertEqual(read.agent, .absent)
        XCTAssertTrue(TabLightRead.of(["pane-other"], tab: tab, in: snapshot).ports.isEmpty, "not read: its tab isn't wanted")

        // Read for its own tab, a pane is still never another tab's.
        let both = try tick(ActivitySampler(kernel: kernel), [left, right, elsewhere], tabs: [tab, other])
        XCTAssertEqual(TabLightRead.of(["pane-other"], tab: other, in: both).ports.map(\.port), [3000])
        XCTAssertTrue(TabLightRead.of(["pane-other"], tab: tab, in: both).ports.isEmpty, "a pane the snapshot has for another tab")
    }

    /// A pill is only for what runs as the user alone (6.10's never-list):
    /// a setuid program the pane runs that has set its effective uid to the
    /// user's for now, root kept as its saved one, is read — its sockets
    /// are the user's to read — but holds no pill, so the pill's Kill, which
    /// `kill(2)` would let through by its real uid, never reaches it.
    func testAPillIsOnlyForWhatRunsAsTheUserAlone() throws {
        typealias K = FakeActivityKernel
        appAndLaunchd()
        let left = pane("pane-left", login: 1100, tab: tab)
        add(1102, parent: 1101, name: "acme-web", sockets: [K.tcp(local: "127.0.0.1", port: 3000)])
        let setuid = add(1103, parent: 1101, savedUID: 0, name: "acme-setuid", sockets: [K.tcp(local: "127.0.0.1", port: 4000, handle: 2)])
        let snapshot = try tick(ActivitySampler(kernel: kernel), [left], tabs: [tab])
        XCTAssertEqual(snapshot.facts[setuid]?.sockets?.records.count, 1, "read: its sockets are the user's to read")
        let read = TabLightRead.of(["pane-left"], tab: tab, in: snapshot)
        XCTAssertEqual(read.ports.map(\.port), [3000], "the setuid program's listener holds no pill")
        XCTAssertEqual(read.panePorts[0]?.map(\.port), [3000])
    }

    /// An agent's folder read since a moment answers over the one the tick
    /// knew (an MCP call's, its window off screen): the worktree it moved
    /// into, not the folder it left; none in time keeps what the tab
    /// follows, and one that can't be read is nothing to follow.
    func testAFolderReadSinceAnswersOverTheOneTheTickKnew() throws {
        appAndLaunchd()
        let left = pane("pane-left", login: 1100, tab: tab)
        add(1102, parent: 1101, name: "claude", folder: "/tmp/acme-checkout")
        let sampler = ActivitySampler(kernel: kernel)
        _ = try tick(sampler, [left], tabs: [tab])
        XCTAssertTrue(TestChild.eventually { !sampler.folders.isBusy })
        let snapshot = try tick(sampler, [left], tabs: [tab])
        XCTAssertTrue(TestChild.eventually { !sampler.folders.isBusy }, "the tick's own read, done")
        // EnterWorktree moves it; then the call comes.
        kernel.update(1102) { $0.folder = "/tmp/acme-checkout/.worktrees/feat" }
        kernel.advance(1_000_000)
        let since = kernel.uptime()
        XCTAssertEqual(TabLightRead.agent(["pane-left"], tab: tab, in: snapshot), .folder("/tmp/acme-checkout"), "the tick's: the one known")
        XCTAssertEqual(
            TabLightRead.agent(["pane-left"], tab: tab, in: snapshot) { sampler.folders.folder(readSince: since, of: $0) },
            .folder("/tmp/acme-checkout/.worktrees/feat"), "a read begun since")
        XCTAssertEqual(TabLightRead.agent(["pane-left"], tab: tab, in: snapshot) { _ in nil }, .unread, "none in time: kept")
        XCTAssertEqual(TabLightRead.agent(["pane-left"], tab: tab, in: snapshot) { _ in .unknown }, .absent)
    }

    /// Where the tab's agent works: the focused pane's first — the poll's
    /// rule —, its folder once the census read it, the tab's own kept while
    /// it isn't read yet; an agent whose folder can't be read is nothing to
    /// follow, and so is no agent at all.
    func testTheFocusedPanesAgentIsFollowed() throws {
        appAndLaunchd()
        let left = pane("pane-left", login: 1100, tab: tab)
        add(1102, parent: 1101, name: "claude", folder: "/tmp/acme-checkout/.worktrees/left")
        let right = pane("pane-right", login: 1200, tab: tab)
        add(1202, parent: 1201, name: "codex", folder: "/tmp/acme-checkout/.worktrees/right")
        let sampler = ActivitySampler(kernel: kernel)
        let first = try tick(sampler, [left, right], tabs: [tab])
        XCTAssertEqual(TabLightRead.of(["pane-right", "pane-left"], tab: tab, in: first).agent, .unread, "asked, not read yet: kept")
        XCTAssertTrue(TestChild.eventually { !sampler.folders.isBusy })
        let second = try tick(sampler, [left, right], tabs: [tab])
        XCTAssertEqual(TabLightRead.of(["pane-right", "pane-left"], tab: tab, in: second).agent, .folder("/tmp/acme-checkout/.worktrees/right"))
        XCTAssertEqual(TabLightRead.of(["pane-left", "pane-right"], tab: tab, in: second).agent, .folder("/tmp/acme-checkout/.worktrees/left"))

        // Its folder can't be read (it ended between, or a refusal): nothing.
        kernel.update(1202) { $0.folder = nil }
        kernel.update(1102) { $0.folder = nil }
        _ = try tick(sampler, [left, right], tabs: [tab])
        XCTAssertTrue(TestChild.eventually { !sampler.folders.isBusy })
        let unreadable = try tick(sampler, [left, right], tabs: [tab])
        XCTAssertEqual(TabLightRead.of(["pane-right", "pane-left"], tab: tab, in: unreadable).agent, .absent)
    }

    /// Docker's "a tab holds the port" from a census of every pane: the
    /// first tab whose pane holds it, with the holder's name — a pane's
    /// tree or what carries its tag —; a process outside every pane, or a
    /// pane the snapshot has for another tab, names none.
    func testTheTabHoldingAPortFromACensus() throws {
        typealias K = FakeActivityKernel
        appAndLaunchd()
        let left = pane("pane-left", login: 1100, tab: tab)
        let elsewhere = pane("pane-other", login: 1400, tab: other)
        add(1402, parent: 1401, name: "acme-web", sockets: [K.tcp(local: "127.0.0.1", port: 3000)])
        add(1500, parent: 1, name: "acme-daemon", sockets: [K.tcp(local: "127.0.0.1", port: 5432, handle: 2)])
        let snapshot = try XCTUnwrap(
            ActivitySampler(kernel: kernel).tickNow(ActivityDemand(.full), context: ActivityContext(panes: [left, elsewhere], appPID: app)))
        let tabs = [(id: tab, title: "acme", tags: ["pane-left"]), (id: other, title: "acme-2", tags: ["pane-other"])]
        let held = try XCTUnwrap(ListeningPorts.tab(holding: 3000, among: tabs, in: snapshot))
        XCTAssertEqual(held.0, other)
        XCTAssertEqual(held.1, "acme-2")
        XCTAssertEqual(held.2, "acme-web")
        XCTAssertNil(ListeningPorts.tab(holding: 5432, among: tabs, in: snapshot), "a process outside every pane is no tab's")
        XCTAssertNil(ListeningPorts.tab(holding: 3000, among: [(id: tab, title: "acme", tags: ["pane-other"])], in: snapshot), "another tab's pane")
    }
}
