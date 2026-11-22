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

/// The Activity page's filter (docs/design/activity/analysis.md, 6.6) over a
/// fake Mac: `ResourceFilter`'s words with Activity's keys, quantities with
/// units, `|` ORing inside a value, masked text only, a match's ancestors
/// kept dimmed in a tree, Listening's own keys. Names are invented.
final class ActivityFilterTests: XCTestCase {
    private let kernel = FakeActivityKernel(uid: 501)
    private let app: pid_t = 1000
    private let tab = UUID()

    @discardableResult
    private func add(
        _ pid: pid_t, parent: pid_t, uid: uid_t = 501, name: String, words: [String]? = nil, cpu: UInt64 = 0, footprint: UInt64 = 8 << 20,
        sockets: [socket_fdinfo] = [], status: Int32 = SRUN
    ) -> ActivityProcessID {
        let start = UInt64(pid) * 1_000
        var process = FakeActivityKernel.Process(
            record: FakeActivityKernel.record(pid: pid, start: start, parent: parent, uid: uid, realUID: uid == 0 ? 501 : nil, status: status, name: name))
        process.name = name
        process.path = uid == 501 ? "/opt/acme/bin/\(name)" : "/usr/libexec/\(name)"
        process.codeSigning = ActivityCodeSigning(flags: ActivityCodeSigning.valid)
        process.usage = FakeActivityKernel.usage(cpuTime: cpu, footprint: footprint, threads: 3)
        process.arguments = FakeActivityKernel.arguments(executable: process.path ?? name, words ?? [name])
        process.descriptors = sockets.indices.map { FakeActivityKernel.descriptor(Int32(3 + $0)) }
        process.sockets = Dictionary(uniqueKeysWithValues: sockets.enumerated().map { (Int32(3 + $0.offset), $0.element) })
        kernel.add(process)
        return ActivityProcessID(pid: pid, start: start)
    }

    /// launchd, the app, a pane: its `login`, a shell, a node server
    /// listening on 5173 and its python worker; one of the user's elsewhere
    /// on 8080 holding 2 GB; root's daemon; a stopped job.
    private func mac() -> ActivityContext {
        add(1, parent: 0, uid: 0, name: "launchd")
        add(app, parent: 1, name: "Overterm")
        let login = add(1100, parent: app, uid: 0, name: "login")
        add(1101, parent: 1100, name: "zsh")
        add(
            1102, parent: 1101, name: "node", words: ["node", "acme-vite.js", "--port", "5173", "--password", "fake-secret-7"],
            sockets: [FakeActivityKernel.tcp(local: "127.0.0.1", port: 5173, handle: 1)])
        add(1103, parent: 1102, name: "python3", words: ["python3", "-m", "acme_worker"])
        add(1104, parent: 1101, name: "acme-job", status: SSTOP)
        add(
            2000, parent: 1, name: "globex-agent", footprint: 2 << 30,
            sockets: [FakeActivityKernel.tcp(local: "0.0.0.0", port: 8080, handle: 3), FakeActivityKernel.udp(local: "0.0.0.0", port: 5353, handle: 4)])
        add(300, parent: 1, uid: 0, name: "fakeservd")
        return ActivityContext(panes: [ActivityContext.Pane(tag: "pane-a", tab: tab, login: login)], appPID: app)
    }

    private func content(
        _ filter: String, grouping: ActivityGrouping? = .checkout, tree: Bool = true, port: String = "", folds: [String: Bool] = [:]
    ) throws -> ActivityPageContent {
        let snapshot = try XCTUnwrap(ActivitySampler(kernel: kernel).tickNow(ActivityDemand(.full), context: mac()))
        var options = ActivityRows.Options(titles: [tab: "web"])
        options.folds = folds
        options.grouping = grouping
        options.tree = tree
        options.processFilter = filter
        options.portFilter = port
        return ActivityRows.content(of: snapshot, options)
    }

    private func names(_ filter: String) throws -> Set<String> { Set(try content(filter).processes.filter { !$0.dimmed }.map(\.name)) }

    func testWordsKeysAndNegation() throws {
        XCTAssertEqual(try names("node"), ["node"], "free text: the name")
        XCTAssertEqual(try names("acme_worker"), ["python3"], "free text: the masked command")
        XCTAssertEqual(try names("web"), ["zsh", "node", "python3", "acme-job"], "free text: the tab's title")
        XCTAssertEqual(try names("pid:1102"), ["node"])
        XCTAssertEqual(try names("ppid:1101"), ["node", "acme-job"])
        XCTAssertEqual(try names("pid:>=2000"), ["globex-agent"])
        XCTAssertEqual(try names("user:root"), ["launchd", "login", "fakeservd"])
        XCTAssertEqual(try names("-user:root").contains("launchd"), false)
        XCTAssertTrue(try names("u:me").isSuperset(of: ["zsh", "node", "globex-agent"]))
        XCTAssertEqual(try names("tab:web name:python"), ["python3"], "words ANDed")
        XCTAssertEqual(try names("state:stopped"), ["acme-job"])
        XCTAssertEqual(try names("is:stopped"), ["acme-job"])
        XCTAssertEqual(try names("is:tab is:listening"), ["node"])
        XCTAssertEqual(try names("port:8080"), ["globex-agent"])
        XCTAssertEqual(try names("port:5353"), ["globex-agent"], "either protocol")
        XCTAssertEqual(try names("port:>8000"), ["globex-agent"])
        XCTAssertEqual(try names("role:server"), ["node", "globex-agent"])
        XCTAssertEqual(try names("pane:1 name:zsh"), ["zsh"])
    }

    /// htop 3.2's `|`: any of the values.
    func testABarInsideAValueORs() throws {
        XCTAssertEqual(try names("name:node|python"), ["node", "python3"])
        XCTAssertEqual(try names("-name:node|python tab:web"), ["zsh", "acme-job"])
    }

    func testQuantitiesWithUnits() throws {
        let agent = try XCTUnwrap(try content("").processes.first { $0.name == "globex-agent" })
        XCTAssertEqual(agent.memory, 2 << 30)
        XCTAssertEqual(try names("mem:>1g"), ["globex-agent"])
        XCTAssertEqual(try names("mem:>1024"), ["globex-agent"], "a bare number is MB")
        XCTAssertEqual(try names("mem:<10m user:me").contains("globex-agent"), false)
        XCTAssertEqual(ActivityQuantity(">500m", unit: .bytes)?.value, 500 * 1024 * 1024)
        XCTAssertEqual(ActivityQuantity("<=1.5gb", unit: .bytes)?.value, 1.5 * 1024 * 1024 * 1024)
        XCTAssertEqual(ActivityQuantity("<5m", unit: .seconds)?.value, 300)
        XCTAssertEqual(ActivityQuantity(">2d", unit: .seconds)?.value, 172_800)
        XCTAssertEqual(ActivityQuantity("90", unit: .seconds)?.op, .equal)
        XCTAssertNil(ActivityQuantity(">5x", unit: .seconds), "no such unit")
        XCTAssertNil(ActivityQuantity(">5m", unit: .plain), "a plain number has none")
        XCTAssertNil(ActivityQuantity(">", unit: .plain))
        // The fake's processes started in 1970: all older than two days.
        XCTAssertEqual(try names("age:<5m"), [])
        XCTAssertTrue(try names("age:>2d").contains("node"))
        XCTAssertEqual(try names("threads:3 name:node"), ["node"])
    }

    /// No rate yet: a CPU filter matches nothing, never a 0 it didn't read.
    func testCPUBeforeARateMatchesNothing() throws {
        XCTAssertEqual(try names("cpu:<1"), [])
    }

    /// Text is matched against the masked command only (9.3): a secret in
    /// another process's arguments is never confirmed a character at a time.
    func testOnlyMaskedTextIsMatched() throws {
        XCTAssertEqual(try names("fake-secret-7"), [])
        XCTAssertEqual(try names("cmd:fake-secret"), [])
        XCTAssertEqual(try names("cmd:--password"), ["node"], "the flag stays, its value doesn't")
    }

    /// In a tree a match keeps its ancestors, dimmed, so it keeps its place;
    /// flat, only the matches.
    func testATreeKeepsAMatchsAncestorsDimmed() throws {
        let grouped = try content("python", grouping: .tab)
        let processes = grouped.list.compactMap { item -> ActivityProcessRow? in if case .process(let row) = item { row } else { nil } }
        XCTAssertEqual(processes.map(\.name), ["login", "zsh", "node", "python3"], "the pane's session, its shell, the server, the match")
        XCTAssertEqual(processes.map(\.dimmed), [true, true, true, false])
        XCTAssertEqual(grouped.summary.matched, 1)
        let flat = try content("python", grouping: .tab, tree: false)
        XCTAssertEqual(flat.processes.map(\.name), ["python3"])
        XCTAssertFalse(flat.processes.contains(where: \.dimmed))
    }

    /// Each section's field is its own (6.6): a Processes filter leaves
    /// Listening, its count, the detail's listeners and the busiest whole.
    func testAProcessFilterLeavesListeningAlone() throws {
        let all = try content("")
        let filtered = try content("name:python")
        XCTAssertEqual(filtered.processes.filter { !$0.dimmed }.map(\.name), ["python3"])
        XCTAssertEqual(filtered.ports.map(\.id), all.ports.map(\.id))
        XCTAssertEqual(filtered.summary.listening, all.summary.listening)
        XCTAssertEqual(filtered.listeners.map(\.id), all.listeners.map(\.id))
        XCTAssertEqual(filtered.identities, all.identities)
        XCTAssertEqual(filtered.summary.busiest.map(\.id), all.summary.busiest.map(\.id))
        // Listening's own filter narrows the section, never the detail's.
        let narrowed = try content("", port: "proto:udp")
        XCTAssertEqual(narrowed.ports.map(\.port), [5353])
        XCTAssertEqual(narrowed.listeners.map(\.id), all.listeners.map(\.id))
    }

    /// A match's dimmed ancestors are its own tree's: up to the pane's
    /// login, never Overterm or launchd pulled into their groups.
    func testAMatchsAncestorsStopAtItsOwnTree() throws {
        for grouping in [ActivityGrouping.checkout, .tab, .agent, .user, .app] {
            let listed = try content("name:python", grouping: grouping).list.compactMap { item -> ActivityProcessRow? in
                if case .process(let row) = item { row } else { nil }
            }
            XCTAssertEqual(listed.filter { !$0.dimmed }.map(\.name), ["python3"], "\(grouping)")
            XCTAssertFalse(listed.contains { $0.name == "Overterm" || $0.name == "launchd" }, "\(grouping): \(listed.map(\.name))")
        }
    }

    /// Filtered, a group folded by default opens on its matches; one the
    /// person folded stays folded.
    func testAMatchInAGroupFoldedByDefaultShows() throws {
        func shown(_ content: ActivityPageContent) -> [String] {
            content.list.compactMap { item -> String? in if case .process(let row) = item, !row.dimmed { row.name } else { nil } }
        }
        XCTAssertFalse(shown(try content("")).contains("fakeservd"), "folded until unfolded")
        let found = try content("name:fakeservd")
        XCTAssertEqual(shown(found), ["fakeservd"])
        XCTAssertEqual(found.summary.matched, 1)
        let group = try XCTUnwrap(
            found.list.first { item in
                if case .group(let row) = item { row.kind == .fixed } else { false }
            })
        XCTAssertEqual(shown(try content("name:fakeservd", folds: [group.id: true])), [], "the person's fold stays")
    }

    func testListeningsOwnKeys() throws {
        func ports(_ filter: String) throws -> [Int] { try content("", port: filter).ports.map(\.port) }
        XCTAssertEqual(try ports(""), [5173, 5353, 8080])
        XCTAssertEqual(try ports("proto:udp"), [5353])
        XCTAssertEqual(try ports("scope:lan"), [5353, 8080])
        XCTAssertEqual(try ports("is:local"), [5173])
        XCTAssertEqual(try ports("owner:tab"), [5173])
        XCTAssertEqual(try ports("owner:elsewhere proto:tcp"), [8080])
        XCTAssertEqual(try ports("family:4"), [5173, 5353, 8080])
        XCTAssertEqual(try ports("port:<6000"), [5173, 5353])
        XCTAssertEqual(try ports("globex"), [5353, 8080], "free text: the process")
        XCTAssertEqual(try ports(":5173"), [5173])
        XCTAssertEqual(try ports("tab:web"), [5173])
        XCTAssertEqual(try ports("-port:5173|8080"), [5353])
    }

    func testAnEmptyFilteredSectionSaysSo() {
        XCTAssertEqual(ActivityPageView.emptySentence(.processes, scopedToRun: false, filter: " name:zz "), "Nothing matches “name:zz”.")
    }
}
