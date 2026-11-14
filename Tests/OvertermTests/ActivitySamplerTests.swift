import Darwin
import Foundation
import XCTest

@testable import Overterm

/// The census's ticks (docs/design/activity/analysis.md, 7.1–7.5, 10.1)
/// over a fake Mac: rates by the interval measured, only over 250 ms and
/// never over a gap, the first sample "—", baselines that survive ticks
/// that read others, the levels, the churn budget (what carries a pane's
/// tag among the level's own), a read still to come told from a failed
/// one, the cache's bound, the in-flight guard, the stretched cadence, the
/// folders' deadline and bound, the app's children for the pairing — then
/// one busy child of the test's through the real kernel.
final class ActivitySamplerTests: XCTestCase {
    private let kernel = FakeActivityKernel(uid: 501)
    private let second: UInt64 = 1_000_000_000
    private let app: pid_t = 1000

    override func tearDown() {
        kernel.onCall(nil)
        super.tearDown()
    }

    // MARK: A fake Mac

    /// A process: the user's unless `uid` says, its argv its name alone
    /// unless `words` says, its usage `cpu` ns of CPU so far.
    @discardableResult
    private func add(
        _ pid: pid_t, start: UInt64? = nil, parent: pid_t, uid: uid_t = 501, name: String = "fake", words: [String]? = nil,
        environment: [String] = [], cpu: UInt64 = 0, restricted: Bool = false, folder: String? = nil, socket: socket_fdinfo? = nil
    ) -> ActivityProcessID {
        let start = start ?? UInt64(pid) * 1_000
        let path = uid == 501 ? "/opt/acme/bin/\(name)" : "/usr/libexec/\(name)"
        var process = FakeActivityKernel.Process(
            record: FakeActivityKernel.record(pid: pid, start: start, parent: parent, uid: uid, realUID: uid == 0 ? 501 : nil, name: name))
        process.name = name
        process.path = path
        process.codeSigning = ActivityCodeSigning(flags: ActivityCodeSigning.valid | (restricted ? ActivityCodeSigning.restrict : 0))
        process.usage = FakeActivityKernel.usage(cpuTime: cpu, footprint: 4 << 20)
        process.arguments = FakeActivityKernel.arguments(executable: path, words ?? [name], environment: environment)
        process.folder = folder
        if let socket {
            process.descriptors = [FakeActivityKernel.descriptor(3)]
            process.sockets = [3: socket]
        }
        kernel.add(process)
        return ActivityProcessID(pid: pid, start: start)
    }

    /// Adds `cpu` ns to a process's CPU time.
    private func burn(_ pid: pid_t, _ cpu: UInt64) {
        kernel.update(pid) { process in
            let used = process.usage?.cpuTime ?? 0
            process.usage = FakeActivityKernel.usage(cpuTime: used + cpu, footprint: 4 << 20)
        }
    }

    /// The app and launchd.
    private func appAndLaunchd() {
        add(1, parent: 0, uid: 0, name: "launchd")
        add(app, parent: 1, name: "Overterm")
    }

    /// A pane: its root-owned `login` under the app, a shell under that.
    private func pane(_ tag: String, login: pid_t, tab: UUID = UUID()) -> ActivityContext.Pane {
        let identity = add(login, parent: app, uid: 0, name: "login")
        add(login + 1, parent: login, name: "zsh", restricted: true)
        return ActivityContext.Pane(tag: tag, tab: tab, login: identity)
    }

    private func sampler(_ limits: ActivitySampler.Limits = ActivitySampler.Limits()) -> ActivitySampler {
        ActivitySampler(kernel: kernel, limits: limits)
    }

    /// A tick, waited for at most 10 s: a tick that waited for a hung
    /// folder would fail here, not hang the run.
    private func tick(_ sampler: ActivitySampler, _ demand: ActivityDemand, _ context: ActivityContext) throws -> ActivitySnapshot {
        let done = DispatchSemaphore(value: 0)
        let box = SnapshotBox()
        sampler.submit(demand, context: context) { snapshot in
            box.set(snapshot)
            done.signal()
        }
        XCTAssertEqual(done.wait(timeout: .now() + 10), .success, "a tick never waits")
        return try XCTUnwrap(box.value)
    }

    // MARK: Rates

    /// The split-tab regression (2.4, item 1): two panes' slices read in
    /// turn, as Tab Info read a split tab pane by pane — each tick reading
    /// one — both read their CPU. ProcessInspector kept only the baselines
    /// of the tree it had just read, so each evicted the other's: 0% and 0%.
    func testTwoPanesReadInTurnBothReadTheirCPU() throws {
        appAndLaunchd()
        let tabA = UUID()
        let tabB = UUID()
        let left = pane("pane-a", login: 1100, tab: tabA)
        let busyLeft = add(1102, parent: 1101, name: "node")
        let right = pane("pane-b", login: 1200, tab: tabB)
        let busyRight = add(1202, parent: 1201, name: "python3")
        let context = ActivityContext(panes: [left, right], appPID: app)
        let sampler = sampler()
        for round in 0..<6 {
            let (tab, busy, other) = round % 2 == 0 ? (tabA, busyLeft, busyRight) : (tabB, busyRight, busyLeft)
            let snapshot = try tick(sampler, ActivityDemand(.light(tabs: [tab])), context)
            let rates = snapshot.facts[busy]?.rates
            if round < 2 {
                XCTAssertNil(rates, "round \(round): a first sample is —, never 0")
            } else {
                // Two seconds since its baseline, two seconds of CPU.
                XCTAssertEqual(try XCTUnwrap(rates, "round \(round)").cpuPercent, 100, accuracy: 1e-6, "round \(round)")
                XCTAssertEqual(try XCTUnwrap(rates).interval, 2 * second)
            }
            XCTAssertNil(snapshot.facts[other], "round \(round): the other pane isn't read")
            kernel.advance(second)
            burn(busyLeft.pid, second)
            burn(busyRight.pid, second)
        }
    }

    /// An identity's first sample is "—"; a reused pid is a new identity,
    /// "—" again; baselines go only with their identity.
    func testAFirstSampleIsADashAndAReusedPidStartsAgain() throws {
        appAndLaunchd()
        let first = add(2000, parent: 1, name: "worker")
        let sampler = sampler()
        XCTAssertNil(try tick(sampler, ActivityDemand(.focus([first])), ActivityContext(appPID: app)).facts[first]?.rates)
        kernel.advance(second)
        burn(2000, second / 2)
        // Ticks that read something else meanwhile leave its baseline be.
        let other = add(2001, parent: 1, name: "other")
        _ = try tick(sampler, ActivityDemand(.focus([other])), ActivityContext(appPID: app))
        kernel.advance(second)
        burn(2000, second / 2)
        let rates = try XCTUnwrap(try tick(sampler, ActivityDemand(.focus([first])), ActivityContext(appPID: app)).facts[first]?.rates)
        XCTAssertEqual(rates.cpuPercent, 50, accuracy: 1e-6, "over the two seconds since its first sample")
        XCTAssertEqual(rates.interval, 2 * second)

        kernel.remove(2000)
        _ = try tick(sampler, ActivityDemand(.focus([other])), ActivityContext(appPID: app))
        let reused = add(2000, start: first.start + 5_000_000, parent: 1, name: "worker", cpu: 9 * second)
        kernel.advance(second)
        let snapshot = try tick(sampler, ActivityDemand(.focus([first, reused])), ActivityContext(appPID: app))
        XCTAssertNil(snapshot.facts[first], "gone")
        XCTAssertNotNil(snapshot.facts[reused]?.usage)
        XCTAssertNil(snapshot.facts[reused]?.rates, "a reused pid is another process: —")
    }

    /// Rates only over 250 ms (7.3): a read 10 ms after a tick gets the
    /// rates last published and leaves the baseline where it was.
    func testRatesOnlyOverAQuarterSecond() throws {
        appAndLaunchd()
        let worker = add(2100, parent: 1, name: "worker")
        let sampler = sampler()
        let demand = ActivityDemand(.focus([worker]))
        _ = try tick(sampler, demand, ActivityContext(appPID: app))
        kernel.advance(second)
        burn(2100, second / 2)
        XCTAssertEqual(try XCTUnwrap(try tick(sampler, demand, ActivityContext(appPID: app)).facts[worker]?.rates).cpuPercent, 50, accuracy: 1e-6)
        kernel.advance(10_000_000)
        burn(2100, 10_000_000)
        let soon = try XCTUnwrap(try tick(sampler, demand, ActivityContext(appPID: app)).facts[worker]?.rates)
        XCTAssertEqual(soon.cpuPercent, 50, accuracy: 1e-6, "the last published: 10 ms is noise")
        XCTAssertEqual(soon.interval, second)
        kernel.advance(990_000_000)
        burn(2100, 490_000_000)
        let later = try XCTUnwrap(try tick(sampler, demand, ActivityContext(appPID: app)).facts[worker]?.rates)
        XCTAssertEqual(later.interval, second, "from the baseline the 10 ms read left")
        XCTAssertEqual(later.cpuPercent, 50, accuracy: 1e-6)
    }

    /// A rate never spans a gap (6.11): a baseline lives as long as its
    /// identity, so a process read again after a while — the page opened
    /// again 20 minutes after it closed, an agent's census after a quiet
    /// hour — would show the gap's average as its CPU now. Past 15 s it is
    /// "—", its baseline begun again, and the next read has its rate.
    func testARateNeverSpansAGap() throws {
        appAndLaunchd()
        let worker = add(2400, parent: 1, name: "worker")
        let sampler = sampler()
        let demand = ActivityDemand(.focus([worker]))
        let context = ActivityContext(appPID: app)
        XCTAssertNil(try tick(sampler, demand, context).facts[worker]?.rates, "—")
        kernel.advance(15 * second)
        burn(2400, 15 * second)
        let steady = try XCTUnwrap(try tick(sampler, demand, context).facts[worker]?.rates, "15 s: a rate still")
        XCTAssertEqual(steady.cpuPercent, 100, accuracy: 1e-6)
        // A core for 45 s, then idle: read again a minute on.
        kernel.advance(60 * second)
        burn(2400, 45 * second)
        XCTAssertNil(try tick(sampler, demand, context).facts[worker]?.rates, "a minute on: —, not 75% as if it were now")
        kernel.advance(2 * second)
        let now = try XCTUnwrap(try tick(sampler, demand, context).facts[worker]?.rates, "the next read: its rate")
        XCTAssertEqual(now.cpuPercent, 0, accuracy: 1e-6, "idle now")
        XCTAssertEqual(now.interval, 2 * second)
    }

    // MARK: Levels

    /// Light: the read panes' processes and Overterm's helpers — usage and
    /// listeners — and markers for the user's processes outside every tree.
    /// Focus: every socket and the folder. Full: every process, the
    /// others' named from their paths, their usage never asked.
    func testEachLevelReadsWhatItSays() throws {
        appAndLaunchd()
        let tab = UUID()
        let shell = pane("pane-a", login: 1100, tab: tab)
        let listener = FakeActivityKernel.tcp(local: "127.0.0.1", port: 5173, handle: 1)
        let connection = FakeActivityKernel.tcp(local: "127.0.0.1", port: 50_000, remote: "127.0.0.1", remotePort: 5432, state: .established, handle: 2)
        let server = add(1102, parent: 1101, name: "node", words: ["node", "server.js", "--token=hunter2"], socket: listener)
        kernel.update(1102) { process in
            process.descriptors = [FakeActivityKernel.descriptor(3), FakeActivityKernel.descriptor(4)]
            process.sockets = [3: listener, 4: connection]
            process.folder = "/tmp/acme-checkout"
        }
        let helper = add(1500, parent: app, name: "kubectl", words: ["kubectl", "proxy"])
        let helperChild = add(1501, parent: 1500, name: "kubectl-helper")
        let elsewhere = add(4000, parent: 1, name: "elsewhere", environment: ["OVERTERM_TAB_ID=pane-b"])
        let daemon = add(300, parent: 1, uid: 0, name: "acmed")
        let otherPane = pane("pane-b", login: 1200)
        let otherShell = ActivityProcessID(pid: 1201, start: 1201 * 1_000)
        let context = ActivityContext(panes: [shell, otherPane], appPID: app)
        let sampler = sampler()

        kernel.resetCounts()
        let light = try tick(sampler, ActivityDemand(.light(tabs: [tab])), context)
        let shellID = ActivityProcessID(pid: 1101, start: 1101 * 1_000)
        XCTAssertEqual(Set(light.facts.keys), [shellID, server, helper, helperChild])
        XCTAssertEqual(kernel.count("usage"), 4, "the pane's and the helpers', none else")
        XCTAssertEqual(light.facts[server]?.sockets?.records.map(\.localPort), [5173], "listeners only")
        XCTAssertEqual(light.facts[server]?.command, "node server.js --token=••••••", "masked as read")
        XCTAssertEqual(light.helpers, [helper, helperChild])
        XCTAssertEqual(light.pane("pane-a")?.tree, [shellID, server])
        XCTAssertNil(light.pane("pane-b"), "a pane not asked for")
        XCTAssertNil(light.facts[otherShell])

        let focused = try tick(sampler, ActivityDemand(.focus([server])), context)
        XCTAssertEqual(focused.facts[server]?.sockets?.records.map(\.localPort), [5173, 50_000], "every socket, peers too")
        XCTAssertTrue(waitForFolders(sampler))
        XCTAssertEqual(try tick(sampler, ActivityDemand(.focus([server])), context).facts[server]?.folder, .path("/tmp/acme-checkout"))

        kernel.resetCounts()
        let full = try tick(sampler, ActivityDemand(.full), context)
        XCTAssertEqual(full.facts.count, full.table.processes.count, "every process")
        XCTAssertEqual(full.facts[daemon]?.name, "acmed", "another user's, named from its path")
        XCTAssertNil(full.facts[daemon]?.usage)
        XCTAssertEqual(full.facts[elsewhere]?.markers?.tab, "pane-b", "its markers, read by the light tick")
        XCTAssertEqual(full.facts[elsewhere]?.command, "elsewhere", "its argv, read at the full level")
        XCTAssertEqual(kernel.count("usage"), full.cost.own, "every one of the user's")
        XCTAssertEqual(full.cost.usageRead, full.cost.own)
        XCTAssertEqual(Set(full.panes.map(\.tag)), ["pane-a", "pane-b"], "every pane at the full level")
    }

    /// A process carrying a pane's tag outside its tree (nohup, disown)
    /// joins the pane's slice with its children, read in full. A process
    /// the tree places has no markers read (9.2): its environment is
    /// never scanned.
    func testTaggedProcessesJoinTheirPaneAndTreesNeedNoMarkers() throws {
        appAndLaunchd()
        let tab = UUID()
        var left = pane("pane-a", login: 1100, tab: tab)
        let inTree = add(1102, parent: 1101, name: "make", environment: ["OVERTERM_TAB_ID=pane-a"])
        let server = add(1300, parent: 1, name: "python3", words: ["python3", "-m", "http.server"], environment: ["OVERTERM_TAB_ID=pane-a"])
        let child = add(1301, parent: 1300, name: "worker")
        let stranger = add(1400, parent: 1, name: "python3", environment: ["OVERTERM_TAB_ID=pane-b"])
        left.title = "web"
        let context = ActivityContext(panes: [left], appPID: app)
        let snapshot = try tick(sampler(), ActivityDemand(.light(tabs: [tab])), context)
        let slice = try XCTUnwrap(snapshot.pane("pane-a"))
        XCTAssertEqual(slice.tagged, [server, child])
        XCTAssertEqual(slice.placed, slice.tree + [server, child])
        XCTAssertEqual(snapshot.facts[server]?.label, "python3 -m http.server")
        XCTAssertNotNil(snapshot.facts[child]?.usage)
        XCTAssertNil(snapshot.facts[stranger], "another pane's tag: not this pane's")
        XCTAssertNil(snapshot.facts[inTree]?.markers, "placed by its tree: its environment isn't read")
        XCTAssertEqual(snapshot.facts[server]?.markers?.tab, "pane-a")
    }

    /// What carries a read pane's tag is the level's own (7.3): once its tag
    /// is known it is read before the strangers' markers, so a crowd of
    /// processes starting outside every tree (a cold start's 860, a build's
    /// churn) never keeps a nohup'd server unread — named from `p_comm`,
    /// no command, no label — tick after tick.
    func testWhatCarriesAPanesTagIsReadBeforeStrangers() throws {
        appAndLaunchd()
        let tab = UUID()
        let left = pane("pane-a", login: 1100, tab: tab)
        // The oldest outside every tree: its markers are read first.
        let server = add(
            1300, start: 2_000, parent: 1, name: "python3", words: ["python3", "-m", "http.server"], environment: ["OVERTERM_TAB_ID=pane-a"])
        let child = add(1301, start: 3_000, parent: 1300, name: "worker")
        for index in 0..<450 { add(pid_t(5000 + index), parent: 1, name: "job\(index)") }
        let context = ActivityContext(panes: [left], appPID: app)
        let sampler = sampler()
        let demand = ActivityDemand(.light(tabs: [tab]))
        let first = try tick(sampler, demand, context)
        XCTAssertEqual(first.facts[server]?.markers?.tab, "pane-a", "its tag known")
        XCTAssertNil(first.facts[server]?.command, "the budget spent on markers before its argv")
        let next = try tick(sampler, demand, context)
        XCTAssertGreaterThan(next.unread, 0, "strangers still wait")
        XCTAssertEqual(next.facts[server]?.label, "python3 -m http.server", "read first, however many wait")
        XCTAssertEqual(next.facts[child]?.isRead, true, "with what it started")
    }

    /// The pane's agent is the first claude or codex in its tree; its
    /// folder is read at every tick, never waited for.
    func testThePanesAgentAndItsFolder() throws {
        appAndLaunchd()
        let tab = UUID()
        let left = pane("pane-a", login: 1100, tab: tab)
        let agent = add(1102, parent: 1101, name: "node", words: ["claude", "--continue"], folder: "/tmp/acme")
        add(1103, parent: 1102, name: "npx", words: ["npx", "@acme/mcp"])
        let context = ActivityContext(panes: [left], appPID: app)
        let sampler = sampler()
        let demand = ActivityDemand(.light(tabs: [tab]))
        let first = try tick(sampler, demand, context)
        XCTAssertEqual(first.pane("pane-a")?.agent, agent)
        XCTAssertEqual(first.pane("pane-a")?.agentKind, .claude)
        XCTAssertTrue(waitForFolders(sampler))
        XCTAssertEqual(try tick(sampler, demand, context).facts[agent]?.folder, .path("/tmp/acme"))
        // EnterWorktree moves it: read again at the next tick.
        kernel.update(1102) { $0.folder = "/tmp/acme-feature" }
        XCTAssertTrue(waitForFolders(sampler))
        _ = try tick(sampler, demand, context)
        XCTAssertTrue(waitForFolders(sampler))
        XCTAssertEqual(try tick(sampler, demand, context).facts[agent]?.folder, .path("/tmp/acme-feature"))
    }

    /// An exec keeps the identity and changes `p_comm`: read again.
    func testAnExecIsReadAgain() throws {
        appAndLaunchd()
        let shim = add(2200, parent: 1, name: "sh", words: ["sh", "-c", "exec acme-server"])
        let sampler = sampler()
        XCTAssertEqual(try tick(sampler, ActivityDemand(.full), ActivityContext(appPID: app)).facts[shim]?.command, "sh -c exec acme-server")
        kernel.update(2200) { process in
            process.record = FakeActivityKernel.record(pid: 2200, start: shim.start, parent: 1, name: "acme-server")
            process.name = "acme-server"
            process.path = "/opt/acme/bin/acme-server"
            process.arguments = FakeActivityKernel.arguments(executable: "/opt/acme/bin/acme-server", ["acme-server", "--port", "8080"])
        }
        let after = try XCTUnwrap(try tick(sampler, ActivityDemand(.full), ActivityContext(appPID: app)).facts[shim])
        XCTAssertEqual(after.command, "acme-server --port 8080")
        XCTAssertEqual(after.name, "acme-server")
    }

    // MARK: Budgets and bounds

    /// The churn budget (7.3): at most 200 new identities read a tick, the
    /// level's own first, then the oldest; the rest named from `p_comm`
    /// until a later tick. The reads stop too once they took their time.
    func testTheChurnBudget() throws {
        appAndLaunchd()
        let tab = UUID()
        let left = pane("pane-a", login: 1100, tab: tab)
        // The pane's newest process is still read first.
        let member = add(1102, start: 9_000_000_000, parent: 1101, name: "acme-dev")
        var crowd: [ActivityProcessID] = []
        for index in 0..<450 { crowd.append(add(pid_t(5000 + index), parent: 1, name: "job\(index)")) }
        let context = ActivityContext(panes: [left], appPID: app)
        let sampler = sampler()
        let first = try tick(sampler, ActivityDemand(.full), context)
        XCTAssertEqual(first.cost.identitiesRead, 200)
        XCTAssertTrue(first.facts[member]?.isRead == true, "the pane's first")
        let read = crowd.filter { first.facts[$0]?.isRead == true }
        XCTAssertEqual(read, Array(crowd.prefix(read.count)), "then the oldest")
        let waiting = try XCTUnwrap(first.facts[crowd[449]])
        XCTAssertFalse(waiting.isRead)
        XCTAssertEqual(waiting.name, "job449", "named from p_comm meanwhile")
        XCTAssertNil(waiting.command)
        XCTAssertGreaterThan(first.unread, 250)
        let second = try tick(sampler, ActivityDemand(.full), context)
        XCTAssertEqual(second.cost.identitiesRead, 200)
        let third = try tick(sampler, ActivityDemand(.full), context)
        XCTAssertEqual(third.unread, 0)
        XCTAssertTrue(crowd.allSatisfy { third.facts[$0]?.isRead == true })

        // A millisecond an argv read: the full level's 24 ms are spent
        // after 25, whatever the count allows.
        for index in 0..<100 { add(pid_t(7000 + index), parent: 1, name: "late\(index)") }
        kernel.onCall { [kernel] call in if call == "arguments" { kernel.advance(1_000_000) } }
        let timed = try tick(sampler, ActivityDemand(.full), context)
        XCTAssertEqual(timed.cost.commandsRead, 25)
        XCTAssertEqual(timed.unread, 75)
    }

    /// `isRead` tells a read still to come from one that failed: a process
    /// of the user's whose markers alone the light level read is named
    /// from its path, its argv waiting for the churn budget — not read
    /// yet; one whose argv the kernel refuses is read all the same, its
    /// command nil.
    func testIsReadWaitsForTheArgv() throws {
        appAndLaunchd()
        let early = add(3000, parent: 1, name: "acme-early")
        let late = add(3001, parent: 1, name: "acme-late")
        let refused = add(3002, parent: 1, name: "acme-refused")
        kernel.update(3002) { $0.arguments = nil }
        var limits = ActivitySampler.Limits()
        limits.identitiesPerTick = 2
        let sampler = sampler(limits)
        let context = ActivityContext(appPID: app)
        // Light ticks read the markers of what runs outside every tree —
        // the app's and the three — two a tick.
        for _ in 0..<2 { _ = try tick(sampler, ActivityDemand(.light(tabs: nil)), context) }
        XCTAssertEqual(sampler.cachedIdentities, 4)
        // The page opens: the app's and the oldest's argv this tick.
        let full = try tick(sampler, ActivityDemand(.full), context)
        XCTAssertEqual(full.facts[early]?.isRead, true)
        XCTAssertEqual(full.facts[early]?.command, "acme-early")
        let waiting = try XCTUnwrap(full.facts[late])
        XCTAssertFalse(waiting.isRead, "its markers read, its argv still to come")
        XCTAssertEqual(waiting.name, "acme-late", "named from its path meanwhile")
        XCTAssertNil(waiting.command)
        XCTAssertEqual(full.facts[refused]?.isRead, false)
        let next = try tick(sampler, ActivityDemand(.full), context)
        XCTAssertEqual(next.facts[late]?.isRead, true)
        XCTAssertEqual(next.facts[late]?.command, "acme-late")
        let failed = try XCTUnwrap(next.facts[refused])
        XCTAssertTrue(failed.isRead, "refused: read all the same")
        XCTAssertNil(failed.command)
    }

    /// The cache's bound (7.3): ended identities go at the tick that no
    /// longer lists them, under the bound too; past it, those least
    /// recently wanted go — never the ones this tick wants.
    func testTheCacheIsBoundedEndedOnesFirst() throws {
        appAndLaunchd()
        let tab = UUID()
        let left = pane("pane-a", login: 1100, tab: tab)
        var members: [ActivityProcessID] = []
        for index in 0..<5 { members.append(add(pid_t(1110 + index), parent: 1101, name: "member\(index)")) }
        for index in 0..<30 { add(pid_t(5000 + index), parent: 1, name: "job\(index)") }
        var limits = ActivitySampler.Limits()
        limits.cacheLimit = 12
        let sampler = sampler(limits)
        let context = ActivityContext(panes: [left], appPID: app)
        _ = try tick(sampler, ActivityDemand(.light(tabs: [tab])), context)
        XCTAssertEqual(sampler.cachedIdentities, 12)
        XCTAssertTrue(Set(members).isSubset(of: sampler.cached), "what the tick wants stays")

        // Under the bound, an ended identity is dropped all the same.
        var roomy = ActivitySampler.Limits()
        roomy.cacheLimit = 100
        let other = self.sampler(roomy)
        _ = try tick(other, ActivityDemand(.full), context)
        let before = other.cachedIdentities
        kernel.remove(5000)
        kernel.remove(5001)
        _ = try tick(other, ActivityDemand(.full), context)
        XCTAssertEqual(other.cachedIdentities, before - 2)
        XCTAssertFalse(other.cached.contains { $0.pid == 5000 || $0.pid == 5001 })
    }

    /// The in-flight guard (7.3): a tick asked for while one runs is
    /// skipped — nothing read, its answer nil at once.
    func testATickInFlightSkipsTheNext() throws {
        appAndLaunchd()
        let gate = CallGate()
        defer { gate.open() }
        kernel.onCall { call in if call == "processes" { gate.hold() } }
        let sampler = sampler()
        let first = DispatchSemaphore(value: 0)
        XCTAssertTrue(sampler.submit(ActivityDemand(.full), context: ActivityContext(appPID: app)) { _ in first.signal() })
        XCTAssertTrue(TestChild.eventually { gate.held == 1 }, "the first tick is in")
        let skipped = SnapshotBox()
        XCTAssertFalse(sampler.submit(ActivityDemand(.full), context: ActivityContext(appPID: app)) { skipped.set($0) })
        XCTAssertNil(skipped.value)
        gate.open()
        XCTAssertEqual(first.wait(timeout: .now() + 10), .success)
        XCTAssertEqual(kernel.count("processes"), 1, "the skipped tick read nothing")
        XCTAssertTrue(sampler.submit(ActivityDemand(.full), context: ActivityContext(appPID: app)) { _ in }, "free again")
    }

    /// The stretched cadence (7.3): three ticks in a row over four times
    /// their level's budget stretch it; a minute of normal ticks brings it
    /// back.
    func testTheCadenceStretchesOnABusyMac() throws {
        appAndLaunchd()
        let sampler = sampler()
        let context = ActivityContext(appPID: app)
        let light = ActivityDemand(.light(tabs: nil))
        let cost = HookValue<UInt64>(0)
        kernel.onCall { [kernel] call in if call == "processes" { kernel.advance(cost.value) } }
        func ticks(_ count: Int, costing nanoseconds: UInt64, _ demand: ActivityDemand) throws -> Bool {
            cost.value = nanoseconds
            var stretched = false
            for _ in 0..<count { stretched = try tick(sampler, demand, context).isStretched }
            return stretched
        }
        XCTAssertFalse(try ticks(2, costing: 10_000_000, light))
        XCTAssertFalse(try ticks(1, costing: 0, light), "not three in a row")
        XCTAssertFalse(try ticks(2, costing: 10_000_000, light))
        XCTAssertTrue(try ticks(1, costing: 10_000_000, light), "a light tick over 8 ms, three in a row")
        XCTAssertTrue(try ticks(1, costing: 0, light), "back only after a minute")
        kernel.advance(30 * second)
        XCTAssertTrue(try ticks(1, costing: 0, light))
        kernel.advance(31 * second)
        XCTAssertFalse(try ticks(1, costing: 0, light), "a minute of normal ticks")
        XCTAssertFalse(try ticks(3, costing: 40_000_000, ActivityDemand(.full)), "a full tick's budget is 12 ms: 48 ms before it is slow")
        XCTAssertTrue(try ticks(3, costing: 50_000_000, ActivityDemand(.full)))
    }

    func testTheCadenceAlone() {
        var cadence = ActivityCadence()
        cadence.record(cost: 9_000_000, full: false, at: 0)
        cadence.record(cost: 9_000_000, full: false, at: 1)
        XCTAssertFalse(cadence.isStretched)
        cadence.record(cost: 9_000_000, full: false, at: 2)
        XCTAssertTrue(cadence.isStretched)
        cadence.record(cost: 1, full: false, at: 2 + ActivityCadence.recovery - 1)
        XCTAssertTrue(cadence.isStretched)
        cadence.record(cost: 1, full: false, at: 2 + ActivityCadence.recovery)
        XCTAssertFalse(cadence.isStretched)
        cadence.record(cost: 47_000_000, full: true, at: 0)
        cadence.record(cost: 47_000_000, full: true, at: 0)
        cadence.record(cost: 47_000_000, full: true, at: 0)
        XCTAssertFalse(cadence.isStretched)
    }

    // MARK: Folders

    /// A folder read that hangs (a dead mount, 7.2): the tick never waits,
    /// the process is "not answering" once 200 ms have passed, skipped a
    /// minute, then asked again.
    func testAFolderThatDoesntAnswer() throws {
        appAndLaunchd()
        let worker = add(2300, parent: 1, name: "worker", folder: "/Volumes/acme-share/work")
        let gate = CallGate()
        defer { gate.open() }
        kernel.onCall { call in if call == "folder" { gate.hold() } }
        let sampler = sampler()
        let demand = ActivityDemand(.focus([worker]))
        let context = ActivityContext(appPID: app)
        XCTAssertNil(try tick(sampler, demand, context).facts[worker]?.folder, "asked, not waited for")
        XCTAssertTrue(TestChild.eventually { gate.held == 1 }, "the read is in")
        kernel.advance(100_000_000)
        XCTAssertNil(try tick(sampler, demand, context).facts[worker]?.folder, "still within its deadline")
        kernel.advance(150_000_000)
        XCTAssertEqual(try tick(sampler, demand, context).facts[worker]?.folder, .notAnswering)
        gate.open()
        XCTAssertTrue(waitForFolders(sampler))
        XCTAssertEqual(try tick(sampler, demand, context).facts[worker]?.folder, .notAnswering, "skipped its minute")
        kernel.advance(61 * second)
        kernel.onCall(nil)
        _ = try tick(sampler, demand, context)
        XCTAssertTrue(waitForFolders(sampler))
        XCTAssertEqual(try tick(sampler, demand, context).facts[worker]?.folder, .path("/Volumes/acme-share/work"))
    }

    /// Working folders are asked at most `foldersPerTick` a tick (7.2), the
    /// panes' agents' first, the rest at a later tick — each answered from
    /// what is known meanwhile.
    func testFoldersAreAskedAtMostSoManyATick() throws {
        appAndLaunchd()
        let tab = UUID()
        let left = pane("pane-a", login: 1100, tab: tab)
        let agent = add(1102, parent: 1101, name: "node", words: ["claude"], folder: "/tmp/acme-agent")
        let workers = (0..<3).map { add(pid_t(2600 + $0), parent: 1, name: "worker\($0)", folder: "/tmp/acme-\($0)") }
        var limits = ActivitySampler.Limits()
        limits.foldersPerTick = 2
        let sampler = sampler(limits)
        let demand = ActivityDemand(.light(tabs: [tab]), .focus(Set(workers)))
        let context = ActivityContext(panes: [left], appPID: app)
        for round in 1...3 {
            let snapshot = try tick(sampler, demand, context)
            XCTAssertEqual(workers.filter { snapshot.facts[$0]?.folder != nil }.count, round - 1, "round \(round): one more a tick")
            XCTAssertTrue(waitForFolders(sampler))
            XCTAssertEqual(kernel.count("folder"), 2 * round, "round \(round): the agent's, and one other")
        }
        let snapshot = try tick(sampler, demand, context)
        XCTAssertEqual(snapshot.facts[agent]?.folder, .path("/tmp/acme-agent"))
        XCTAssertEqual(workers.map { snapshot.facts[$0]?.folder }, (0..<3).map { .path("/tmp/acme-\($0)") })
    }

    private func waitForFolders(_ sampler: ActivitySampler) -> Bool {
        TestChild.eventually { !sampler.folders.isBusy }
    }

    // MARK: Names

    func testNames() {
        XCTAssertEqual(
            ActivitySampler.name(comm: "com.docker.backe", procName: "com.docker.backe", path: "/Applications/Docker.app/Contents/MacOS/com.docker.backend"), "com.docker.backend",
            "p_comm completed by the path")
        XCTAssertEqual(ActivitySampler.name(comm: "node", procName: "vite", path: "/opt/acme/bin/node"), "vite", "pbi_name when set")
        XCTAssertEqual(ActivitySampler.name(comm: "acmed", procName: nil, path: "/usr/libexec/acmed"), "acmed", "another user's: its path's file")
        XCTAssertEqual(ActivitySampler.name(comm: "acmed", procName: nil, path: nil), "acmed")
    }

    // MARK: The pairing

    /// What the main actor pairs surfaces with (7.7): the app's children,
    /// oldest first — a `login` that ended before it was paired left out,
    /// or the next surface's would shift onto it (7.10).
    func testTheAppsChildrenLeaveOutAZombie() throws {
        appAndLaunchd()
        _ = pane("pane-a", login: 1100)
        kernel.add(
            FakeActivityKernel.Process(
                record: FakeActivityKernel.record(pid: 1200, start: 1_200_000, parent: app, uid: 0, status: SZOMB, name: "login")))
        _ = pane("pane-c", login: 1300)
        let helper = add(1400, parent: app, name: "git")
        let snapshot = try tick(sampler(), ActivityDemand(.light(tabs: nil)), ActivityContext(appPID: app))
        XCTAssertEqual(snapshot.children(ofApp: app).map(\.pid), [1100, 1300, helper.pid])
        XCTAssertEqual(snapshot.children(ofApp: app).map(\.name), ["login", "login", "git"])
    }

    // MARK: The real kernel

    /// A busy child of the test's (10.2), through the sampler and the real
    /// kernel: its first sample "—", then a rate above 0. Only it is read
    /// in focus; the table is read as every tick reads it, and nothing of
    /// any other process goes into an assertion.
    func testARealBusyChildReadsItsCPU() throws {
        let child = try TestChild("/bin/sh", ["-c", "ulimit -c 0; ulimit -t 20; while :; do :; done"])
        defer { child.stop() }
        let sampler = ActivitySampler(kernel: LiveActivityKernel())
        let demand = ActivityDemand(.focus([child.identity]))
        let context = ActivityContext()
        let first = try XCTUnwrap(sampler.tickNow(demand, context: context))
        XCTAssertNotNil(first.facts[child.identity]?.usage)
        XCTAssertNil(first.facts[child.identity]?.rates, "—")
        var rates: ActivityRates?
        XCTAssertTrue(
            TestChild.eventually(30) {
                rates = sampler.tickNow(demand, context: context)?.facts[child.identity]?.rates
                return (rates?.cpuPercent ?? 0) > 0
            })
        XCTAssertGreaterThanOrEqual(try XCTUnwrap(rates).interval, ProcessUsage.minimumInterval)
        XCTAssertGreaterThan(try XCTUnwrap(rates).cpuPercent, 0)
    }
}

/// One snapshot, handed from the sampler's queue.
final class SnapshotBox: @unchecked Sendable {
    private let lock = NSLock()
    private var snapshot: ActivitySnapshot?
    func set(_ snapshot: ActivitySnapshot?) { lock.withLock { self.snapshot = snapshot } }
    var value: ActivitySnapshot? { lock.withLock { snapshot } }
}

/// A value a fake kernel's hook reads while the test changes it.
final class HookValue<Value: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: Value
    init(_ value: Value) { stored = value }
    var value: Value {
        get { lock.withLock { stored } }
        set { lock.withLock { stored = newValue } }
    }
}

/// Holds a fake kernel's calls until the test opens it: a tick in flight,
/// a folder on a mount that doesn't answer.
final class CallGate: @unchecked Sendable {
    private let lock = NSLock()
    private let opened = DispatchSemaphore(value: 0)
    private var holding = 0
    private var isOpen = false

    /// Calls held so far.
    var held: Int { lock.withLock { holding } }

    /// From the fake's hook: waits until `open`.
    func hold() {
        let wait = lock.withLock { () -> Bool in
            guard !isOpen else { return false }
            holding += 1
            return true
        }
        if wait { opened.wait() }
    }

    func open() {
        let waiting = lock.withLock { () -> Int in
            guard !isOpen else { return 0 }
            isOpen = true
            return holding
        }
        for _ in 0..<waiting { opened.signal() }
    }
}
