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

/// Tab Info over the census's light slice for its tab (docs/design/activity/
/// analysis.md, 6.12), on a fake Mac: a split tab one group per pane, each
/// labelled, the shell its group's dimmed root, what left a pane's
/// terminal under it, marked; both panes' busy children reading their CPU
/// — the 0% of a split tab gone —; the footprint shown; the ports from the
/// census's sockets, no lsof. Tabs are real and surfaceless here: no shell
/// is spawned, the panes' processes are the fake's.
@MainActor
final class TabInfoModelTests: XCTestCase {
    private let kernel = FakeActivityKernel(uid: 501)
    private let second: UInt64 = 1_000_000_000
    private let app: pid_t = 1000

    @discardableResult
    private func add(
        _ pid: pid_t, parent: pid_t, uid: uid_t = 501, name: String, words: [String]? = nil, environment: [String] = [],
        listener: socket_fdinfo? = nil
    ) -> ActivityProcessID {
        let start = UInt64(pid) * 1_000
        let path = "/opt/acme/bin/\(name)"
        var process = FakeActivityKernel.Process(record: FakeActivityKernel.record(pid: pid, start: start, parent: parent, uid: uid, name: name))
        process.name = name
        process.path = path
        process.codeSigning = ActivityCodeSigning(flags: ActivityCodeSigning.valid)
        process.usage = FakeActivityKernel.usage(footprint: 8 << 20)
        process.arguments = FakeActivityKernel.arguments(executable: path, words ?? [name], environment: environment)
        if let listener {
            process.descriptors = [FakeActivityKernel.descriptor(3), FakeActivityKernel.descriptor(4)]
            process.sockets = [3: listener, 4: FakeActivityKernel.udp(local: "127.0.0.1", port: 5353)]
        }
        kernel.add(process)
        return ActivityProcessID(pid: pid, start: start)
    }

    private func burn(_ pid: pid_t, _ cpu: UInt64) {
        kernel.update(pid) { process in
            process.usage = FakeActivityKernel.usage(cpuTime: (process.usage?.cpuTime ?? 0) + cpu, footprint: 8 << 20)
        }
    }

    func testASplitTabIsAGroupPerPaneEachReadingItsCPU() throws {
        add(1, parent: 0, uid: 0, name: "launchd")
        add(app, parent: 1, name: "Overterm")
        let left = TerminalView()
        let right = TerminalView()
        let tab = Tab(terminal: left)
        tab.setSplits(SplitTree.leaf(left).inserting(right, at: left, .right))
        let loginA = add(1100, parent: app, uid: 0, name: "login")
        add(1101, parent: 1100, name: "zsh")
        let busyLeft = add(1102, parent: 1101, name: "node", words: ["node", "server.js", "--token=acme-not-a-secret"])
        let loginB = add(1200, parent: app, uid: 0, name: "login")
        add(1201, parent: 1200, name: "zsh")
        let busyRight = add(1202, parent: 1201, name: "python3", listener: FakeActivityKernel.tcp(local: "127.0.0.1", port: 3000))
        // Left its terminal: started in the left pane, nohup'd, reparented.
        let server = add(3000, parent: 1, name: "acme-server", environment: ["OVERTERM_TAB_ID=\(left.processTag)"])
        let worker = add(3001, parent: 3000, name: "acme-worker")
        let context = ActivityContext(
            panes: [
                ActivityContext.Pane(tag: left.processTag, tab: tab.id, login: loginA),
                ActivityContext.Pane(tag: right.processTag, tab: tab.id, login: loginB),
            ], appPID: app)
        let sampler = ActivitySampler(kernel: kernel)
        let model = TabInfoModel(tab: tab, monitor: ActivityMonitor(sampler: sampler), claudeReader: ClaudeUsageReader()) { pane in
            pane === left ? "pnpm dev --password hunter-acme" : nil
        }
        XCTAssertFalse(model.hasRead)
        for _ in 0..<3 {
            model.take(try XCTUnwrap(sampler.tickNow(ActivityDemand(.light(tabs: [tab.id])), context: context)))
            kernel.advance(second)
            burn(busyLeft.pid, second / 2)
            burn(busyRight.pid, second / 4)
        }
        XCTAssertTrue(model.hasRead)
        XCTAssertEqual(model.panes.map(\.id), [left.processTag, right.processTag], "one group per pane, in the tab's order")
        XCTAssertEqual(model.panes.map(\.label), ["pnpm dev --password ••••••", "Pane 2"], "what each runs, masked, else a name")
        let nodes = model.processes.flatMap(\.flattened)
        XCTAssertEqual(nodes.first { $0.identity == busyLeft }?.cpuPercent ?? 0, 50, accuracy: 1e-6, "the left pane's CPU")
        XCTAssertEqual(nodes.first { $0.identity == busyRight }?.cpuPercent ?? 0, 25, accuracy: 1e-6, "and the right's")
        XCTAssertEqual(model.totalCPU ?? 0, 75, accuracy: 1e-6)
        XCTAssertEqual(model.totalFootprint, 6 * (8 << 20), "the footprints: two shells, two jobs, two that left")
        XCTAssertEqual(model.panes[0].leftTerminal.map(\.identity), [server])
        XCTAssertEqual(model.panes[0].leftTerminal.first?.children.map(\.identity), [worker])
        XCTAssertTrue(model.panes[1].leftTerminal.isEmpty)

        let rows = model.rows
        func process(_ row: TabInfoModel.Row) -> (name: String, depth: Int, shell: Bool, left: Bool)? {
            guard case .process(let node, let depth, let isShell, let leftTerminal) = row.kind else { return nil }
            return (node.name, depth, isShell, leftTerminal)
        }
        XCTAssertEqual(rows.first?.kind, .pane("pnpm dev --password ••••••"))
        XCTAssertEqual(rows.compactMap(process).map(\.name), ["zsh", "node", "acme-server", "acme-worker", "zsh", "python3"])
        XCTAssertEqual(rows.compactMap(process).map(\.depth), [0, 1, 1, 2, 0, 1])
        XCTAssertEqual(rows.compactMap(process).map(\.shell), [true, false, false, false, true, false], "the shell, its group's dimmed root")
        XCTAssertEqual(rows.compactMap(process).map(\.left), [false, false, true, false, false, false], "left its terminal, marked")
        XCTAssertEqual(rows.filter { if case .pane = $0.kind { true } else { false } }.count, 2)
        XCTAssertEqual(Set(rows.map(\.id)).count, rows.count, "every row its own id")
        XCTAssertFalse(TabInfoModel.rows(model.panes, split: false).contains { if case .pane = $0.kind { true } else { false } }, "one pane: no label")

        XCTAssertEqual(model.ports.map(\.port), [3000], "TCP listeners from the census's sockets — no UDP, no lsof")
        XCTAssertEqual(model.ports.first?.pid, busyRight.pid)
        XCTAssertEqual(model.ports.first?.address, "127.0.0.1")

        let node = try XCTUnwrap(nodes.first { $0.identity == busyLeft })
        let help = TabInfoView.help(for: node)
        XCTAssertTrue(help.hasPrefix("node server.js --token=••••••"), "the masked command")
        XCTAssertFalse(help.contains("acme-not-a-secret"))
        XCTAssertTrue(help.contains("Started "))
        XCTAssertTrue(TabInfoView.memoryHelp(for: node).contains("real memory (RSS)"))
        XCTAssertEqual(TabInfoView.cpu(nil), "—", "a first sample has no rate")
        model.stop()
    }

    /// A snapshot that didn't read the tab — another reader's, another
    /// tab's — changes nothing.
    func testASnapshotOfAnotherTabIsLeftAlone() throws {
        add(1, parent: 0, uid: 0, name: "launchd")
        add(app, parent: 1, name: "Overterm")
        let pane = TerminalView()
        let tab = Tab(terminal: pane)
        let login = add(1100, parent: app, uid: 0, name: "login")
        add(1101, parent: 1100, name: "zsh")
        let other = UUID()
        let context = ActivityContext(panes: [ActivityContext.Pane(tag: pane.processTag, tab: tab.id, login: login)], appPID: app)
        let sampler = ActivitySampler(kernel: kernel)
        let model = TabInfoModel(tab: tab, monitor: ActivityMonitor(sampler: sampler), claudeReader: ClaudeUsageReader())
        model.take(try XCTUnwrap(sampler.tickNow(ActivityDemand(.light(tabs: [other])), context: context)))
        XCTAssertFalse(model.hasRead)
        XCTAssertTrue(model.panes.isEmpty)
        model.take(try XCTUnwrap(sampler.tickNow(ActivityDemand(.light(tabs: [tab.id])), context: context)))
        XCTAssertEqual(model.processes.map(\.name), ["zsh"])
    }

    /// Ports as the census's sockets say: a process's v4 and v6 listeners
    /// on one port one entry, a wildcard `*`, v6 bracketed, a listener's
    /// only — what lsof printed, without lsof.
    func testPortsFromTheCensussSockets() throws {
        add(1, parent: 0, uid: 0, name: "launchd")
        add(app, parent: 1, name: "Overterm")
        var process = FakeActivityKernel.Process(record: FakeActivityKernel.record(pid: 2000, start: 2_000_000, parent: 1, name: "acme-dev"))
        process.usage = FakeActivityKernel.usage()
        process.descriptors = (3...7).map { FakeActivityKernel.descriptor($0) }
        process.sockets = [
            3: FakeActivityKernel.tcp(local: "127.0.0.1", port: 5173), 4: FakeActivityKernel.tcp(local: "::1", port: 5173, handle: 2),
            5: FakeActivityKernel.tcp(local: "::", port: 8080, dualStack: true, handle: 3), 6: FakeActivityKernel.tcp(local: "::1", port: 9229, handle: 4),
            7: FakeActivityKernel.tcp(local: "127.0.0.1", port: 49_152, remote: "127.0.0.1", remotePort: 5173, state: .established, handle: 5),
        ]
        kernel.add(process)
        let identity = ActivityProcessID(pid: 2000, start: 2_000_000)
        let snapshot = try XCTUnwrap(ActivitySampler(kernel: kernel).tickNow(ActivityDemand(.focus([identity])), context: ActivityContext(appPID: app)))
        let ports = ListeningPorts.of([identity], in: snapshot)
        XCTAssertEqual(ports.map(\.port), [5173, 8080, 9229])
        XCTAssertEqual(ports.map(\.address), ["127.0.0.1", "*", "[::1]"])
        // Opened where they listen (6.8): both families on loopback or a
        // dual-stack wildcard as localhost, ::1 alone in brackets.
        XCTAssertEqual(ports.map(\.url?.absoluteString), ["http://localhost:5173", "http://localhost:8080", "http://[::1]:9229"])
        XCTAssertEqual(ports.map(\.families), [[.v4, .v6], [.v4, .v6], [.v6]])
        XCTAssertEqual(ports.map(\.scope), [.thisMac, .network, .thisMac])
        XCTAssertEqual(ports.map(\.proto), ["tcp", "tcp", "tcp"])
        XCTAssertTrue(ports.allSatisfy { $0.identity == identity }, "the holder's identity, for a pill's verb")
        XCTAssertTrue(ListeningPorts.of([], in: snapshot).isEmpty)
    }

    func testTabInfosListeningRowSaysItsSocket() {
        var port = ListeningPort(pid: 4242, process: "acme-server", port: 3000, address: "127.0.0.1")
        port.families = [.v4, .v6]
        XCTAssertEqual(TabInfoView.portWords(port), "tcp · v4 + v6 · This Mac")
        port.families = .v4
        port.scope = .network
        XCTAssertEqual(TabInfoView.portWords(port), "tcp · v4 · Network")
        var container = ListeningPort(pid: 0, process: "acme-db", port: 5432, address: "*")
        container.container = "acme-db"
        XCTAssertEqual(TabInfoView.portWords(container), "tcp · This Mac", "a container's families aren't read")
    }
}
