import Darwin
import Foundation
import XCTest

@testable import Overterm
@testable import OvertermActivity
@testable import OvertermShell

/// The Activity page's keys in every section (docs/design/activity/
/// analysis.md, 6.3): a key does what the row's menu says it does in
/// Listening and Left Behind too; one that can't be done now beeps and
/// says the reason the menu greys it with; the view — grouping, tree or
/// flat, the sorts — kept across launches (9.5). Over a fake Mac; every
/// name and path is invented.
@MainActor
final class ActivityPageKeysTests: XCTestCase {
    private let kernel = FakeActivityKernel(uid: 501)
    private let app: pid_t = 1000
    private let tab = UUID()

    override func tearDown() async throws {
        ActivityPageModel.forgetView()
    }

    @discardableResult
    private func add(_ pid: pid_t, parent: pid_t, uid: uid_t = 501, name: String, environment: [String] = [], port: UInt16? = nil) -> ActivityProcessID {
        let start = UInt64(pid) * 1_000
        var process = FakeActivityKernel.Process(
            record: FakeActivityKernel.record(pid: pid, start: start, parent: parent, uid: uid, realUID: uid == 0 ? 501 : nil, name: name))
        process.name = name
        process.path = "/opt/acme/bin/\(name)"
        process.codeSigning = ActivityCodeSigning(flags: ActivityCodeSigning.valid)
        process.usage = FakeActivityKernel.usage(cpuTime: 0, footprint: UInt64(pid) << 20, threads: 2)
        process.arguments = FakeActivityKernel.arguments(executable: process.path ?? name, [name], environment: environment)
        process.folder = "/tmp/acme-shop/\(name)"
        if let port {
            process.descriptors = [FakeActivityKernel.descriptor(3)]
            process.sockets = [3: FakeActivityKernel.tcp(local: "127.0.0.1", port: port, handle: UInt64(pid))]
        }
        kernel.add(process)
        return ActivityProcessID(pid: pid, start: start)
    }

    /// A pane's server on :5173, one of the user's outside every tab, and
    /// what a closed pane left: a server on :3001 carrying its tag.
    private func mac() -> ActivityContext {
        add(1, parent: 0, uid: 0, name: "launchd")
        add(app, parent: 1, name: "Overterm")
        let login = add(1100, parent: app, uid: 0, name: "login")
        add(1101, parent: 1100, name: "zsh")
        add(1102, parent: 1101, name: "acme-server", port: 5173)
        add(2000, parent: 1, name: "globex-tool")
        add(1800, parent: 1, name: "acme-left", environment: ["OVERTERM_TAB_ID=pane-gone"], port: 3001)
        var context = ActivityContext(panes: [ActivityContext.Pane(tag: "pane-a", tab: tab, login: login)], appPID: app)
        context.retired = [
            ActivityContext.RetiredPane(
                pane: ActivityContext.Pane(tag: "pane-gone", tab: UUID(), title: "api", checkout: "/tmp/acme-shop", agent: nil),
                closed: Date(timeIntervalSince1970: 1_700_000_000))
        ]
        return context
    }

    final class Box {
        var sampled: [pid_t] = []
        var tabInfo: [UUID] = []
        var revealed: [String] = []
        var beeps = 0
    }

    private func page() async throws -> (ActivityPageModel, ActivityMonitor, Box) {
        let monitor = ActivityMonitor(sampler: ActivitySampler(kernel: kernel))
        monitor.setContext(mac())
        monitor.interval = .milliseconds(300)
        let page = ActivityPageModel(monitor: monitor)
        page.isolated = false
        page.tabTitles = { [tab] in [tab: "web"] }
        let box = Box()
        page.actions.sample = { box.sampled.append($0) }
        page.actions.tabInfo = { box.tabInfo.append($0) }
        page.actions.reveal = { box.revealed.append($0) }
        page.actions.beep = { box.beeps += 1 }
        page.visible = true
        let read = await eventually { page.hasRead }
        XCTAssertTrue(read)
        return (page, monitor, box)
    }

    // MARK: ACT-U2: every section

    /// Listening: a listener's holder is the row's process — `s`, `l`, `i`
    /// and `r` do what its menu offers; `t` and the sort keys aren't
    /// Listening's, and say so.
    func testListeningsKeysDoWhatItsMenuSays() async throws {
        let (page, monitor, box) = try await page()
        defer { monitor.stop() }
        XCTAssertTrue(page.press("2"))
        let listed = await eventually { page.content.ports.contains { $0.port == 5173 && $0.kind == .listener } }
        XCTAssertTrue(listed)
        let port = try XCTUnwrap(page.content.ports.first { $0.port == 5173 && $0.kind == .listener })
        page.selection = [port.id]
        XCTAssertEqual(page.detail?.row.identity.pid, 1102, "the holder's detail")
        let verbs = page.verbs(for: [port.id]) { _ in }
        XCTAssertNotNil(verbs.first { $0.key == "s" }, "the menu offers Sample")
        XCTAssertTrue(page.press("s"))
        XCTAssertEqual(box.sampled, [1102], "s samples the holder, as the menu does")
        XCTAssertTrue(page.press("i"))
        XCTAssertEqual(box.tabInfo, [tab])
        XCTAssertTrue(page.press("r"))
        XCTAssertEqual(box.revealed, ["/opt/acme/bin/acme-server"])
        XCTAssertTrue(page.press("l"))
        XCTAssertTrue(page.showsFiles, "l reads the holder's open files")
        XCTAssertEqual(box.beeps, 0)
        let tree = page.tree
        XCTAssertTrue(page.press("t"))
        XCTAssertEqual(page.tree, tree, "Listening isn't a tree")
        XCTAssertEqual(page.keySaid, ActivityPageModel.arrangesProcesses(.tree, in: .listening))
        XCTAssertTrue(page.press("N"))
        XCTAssertEqual(page.keySaid, ActivityPageModel.listeningSorts)
        XCTAssertEqual(box.beeps, 2)
    }

    /// Left Behind lists processes: `s`, `l` and the sort keys work there;
    /// `t` and `G` say it is grouped by checkout.
    func testLeftBehindsKeysDoWhatItsMenuSays() async throws {
        let (page, monitor, box) = try await page()
        defer { monitor.stop() }
        XCTAssertTrue(page.press("3"))
        let listed = await eventually { page.content.processes.contains { $0.name == "acme-left" && $0.owner?.place == .leftBehind } }
        XCTAssertTrue(listed)
        let left = try XCTUnwrap(page.content.processes.first { $0.name == "acme-left" })
        page.selection = [left.id]
        XCTAssertEqual(page.detail?.row.identity, left.identity)
        XCTAssertTrue(page.press("s"))
        XCTAssertEqual(box.sampled, [1800])
        XCTAssertTrue(page.press("l"))
        XCTAssertTrue(page.showsFiles)
        XCTAssertTrue(page.press("N"))
        XCTAssertEqual(page.processSort, ResourceSort(column: "pid"), "Left Behind sorts its processes")
        XCTAssertTrue(page.press("I"))
        XCTAssertEqual(page.processSort, ResourceSort(column: "pid", ascending: false))
        XCTAssertEqual(box.beeps, 0)
        let grouping = page.grouping
        XCTAssertTrue(page.press("G"))
        XCTAssertEqual(page.grouping, grouping)
        XCTAssertEqual(page.keySaid, "G arranges Processes (1): Left Behind is grouped by checkout")
        XCTAssertEqual(box.beeps, 1)
    }

    // MARK: ACT-U3: the reason

    /// A key whose verb is greyed beeps and says the menu's own reason;
    /// the next key, or the person's hand, clears it.
    func testAKeyThatCantBeDoneSaysTheMenusReason() async throws {
        let (page, monitor, box) = try await page()
        defer { monitor.stop() }
        XCTAssertTrue(page.press("s"))
        XCTAssertEqual(page.keySaid, ActivityPageModel.nothingSelected)
        XCTAssertEqual(box.beeps, 1)
        let tool = try XCTUnwrap(page.content.processes.first { $0.name == "globex-tool" })
        page.selection = [tool.id]
        XCTAssertNil(page.keySaid, "a selection by hand clears it")
        let verbs = page.verbs(for: [tool.id]) { _ in }
        for key in ["i", "o"] {
            let reason = try XCTUnwrap(verbs.first { $0.key == key }?.unavailable, key)
            XCTAssertTrue(page.press(key))
            XCTAssertEqual(page.keySaid, reason, "\(key): the menu's words")
        }
        XCTAssertEqual(page.keySaid, "Nothing it listens on opens in a browser")
        XCTAssertTrue(page.press("f"))
        XCTAssertEqual(page.keySaid, ActivityPageModel.freeIsListenings)
        XCTAssertTrue(page.press("c"))
        XCTAssertFalse(page.connections)
        XCTAssertEqual(page.keySaid, ActivityPageModel.connectionsAreListenings)
        // Another user's: the sample's reason.
        let login = try XCTUnwrap(page.content.processes.first { $0.name == "login" })
        page.selection = [login.id]
        XCTAssertTrue(page.press("s"))
        XCTAssertEqual(page.keySaid, "Another user's: sample can't read it")
        XCTAssertTrue(page.press("l"))
        XCTAssertEqual(page.keySaid, ActivityPageModel.othersFiles)
        XCTAssertEqual(box.sampled, [], "nothing done")
        XCTAssertEqual(box.beeps, 7)
        XCTAssertTrue(page.press("F"), "a key that works")
        XCTAssertNil(page.keySaid, "clears what the last one said")
        page.visible = false
        XCTAssertNil(page.keySaid)
    }

    // MARK: ACT-U5: the view kept

    func testTheGroupingTreeAndSortsAreKeptAcrossLaunches() async throws {
        let (page, monitor, _) = try await page()
        defer { monitor.stop() }
        page.grouping = .agent
        page.tree = false
        page.processSort = ResourceSort(column: "pid")
        page.portSort = ResourceSort(column: "process", ascending: false)
        // The next launch's page builds them as they were left.
        let again = ActivityPageModel(monitor: monitor)
        XCTAssertEqual(again.grouping, .agent)
        XCTAssertFalse(again.tree)
        XCTAssertEqual(again.processSort, ResourceSort(column: "pid"))
        XCTAssertEqual(again.portSort, ResourceSort(column: "process", ascending: false))
        page.processSort = nil
        XCTAssertNil(ActivityPageModel(monitor: monitor).processSort, "no sort is kept as none")
        ActivityPageModel.forgetView()
        let fresh = ActivityPageModel(monitor: monitor)
        XCTAssertEqual(fresh.grouping, .checkout)
        XCTAssertTrue(fresh.tree)
        XCTAssertEqual(fresh.processSort, ResourceSort(column: "cpu", ascending: false))
        XCTAssertEqual(fresh.portSort, ResourceSort(column: "port"))
    }

    func testASortsTextRoundTrips() {
        for sort in [ResourceSort(column: "cpu", ascending: false), ResourceSort(column: "pid"), nil] {
            XCTAssertEqual(ActivityPageModel.sort(fromText: ActivityPageModel.sortText(sort)), .some(sort))
        }
        XCTAssertNil(ActivityPageModel.sort(fromText: "cpu"), "not a kept sort: the default stays")
        XCTAssertNil(ActivityPageModel.sort(fromText: "cpu:sideways"))
    }

    // MARK: ACT-U8: Tab Info's Free

    func testTabInfosFreeFindsThePaneThatHoldsThePort() {
        let server = ActivityProcessID(pid: 1102, start: 1_102_000)
        let other = ActivityProcessID(pid: 2102, start: 2_102_000)
        let placed: [(tag: String, members: [ActivityProcessID])] = [("pane-a", [other]), ("pane-b", [server])]
        XCTAssertEqual(TabInfoModel.paneTag(holding: server, placed: placed), "pane-b")
        XCTAssertNil(TabInfoModel.paneTag(holding: ActivityProcessID(pid: 1102, start: 9), placed: placed), "a pid come round again holds nothing")
        XCTAssertEqual(TabInfoView.freeTitle(ListeningPort(pid: 1102, process: "acme-server", port: 5173, address: "127.0.0.1")), "Free…")
    }

    private func eventually(_ seconds: Double = 10, _ condition: @MainActor () -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(20))
        }
        return condition()
    }
}
