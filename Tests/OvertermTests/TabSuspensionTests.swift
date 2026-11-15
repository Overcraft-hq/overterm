import XCTest

@testable import Overterm

final class TabSuspensionTests: XCTestCase {
    private func node(_ pid: pid_t, _ parent: pid_t, _ children: [ProcessNode] = []) -> ProcessNode {
        ProcessNode(identity: ActivityProcessID(pid: pid, start: UInt64(pid)), parent: parent, name: "p\(pid)", maskedCommand: "", cpuPercent: 0, memory: 0, workingDirectory: nil, children: children)
    }

    /// The shell before what it runs: stopped the other way round, it
    /// would see its job stop and take the terminal back.
    func testParentsStopBeforeTheirChildren() {
        let shell = node(10, 1, [node(20, 10, [node(30, 20)]), node(21, 10)])
        let order = TabSuspension.order([shell, node(40, 1)])
        XCTAssertEqual(order.first, 10)
        for (child, parent) in [(20, 10), (30, 20), (21, 10)] {
            XCTAssertLessThan(order.firstIndex(of: pid_t(parent))!, order.firstIndex(of: pid_t(child))!)
        }
        XCTAssertEqual(Set(order), [10, 20, 30, 21, 40])
    }

    /// What it stops is read at the press, as the scan it replaced read it
    /// (docs/design/activity/analysis.md, 7.8): the census's other readers
    /// answer from a snapshot up to a tick old, and a tab suspended from
    /// one would keep running what started since — the command just typed —
    /// under the cover, its shell stopped. Over a fake Mac: nothing is
    /// signalled.
    func testWhatItStopsIsReadAtThePress() {
        let kernel = FakeActivityKernel(uid: 501)
        func add(_ pid: pid_t, parent: pid_t, uid: uid_t = 501, name: String) {
            var process = FakeActivityKernel.Process(
                record: FakeActivityKernel.record(pid: pid, start: UInt64(pid) * 1_000, parent: parent, uid: uid, realUID: uid == 0 ? 501 : nil, name: name))
            process.name = name
            process.arguments = FakeActivityKernel.arguments(executable: "/opt/acme/bin/\(name)", [name])
            kernel.add(process)
        }
        add(1, parent: 0, uid: 0, name: "launchd")
        add(1000, parent: 1, name: "Overterm")
        add(1100, parent: 1000, uid: 0, name: "login")
        add(1101, parent: 1100, name: "zsh")
        let census = ActivitySampler(kernel: kernel)
        census.appContext = ActivityContext(
            panes: [ActivityContext.Pane(tag: "pane-a", tab: UUID(), login: ActivityProcessID(pid: 1100, start: 1_100_000))], appPID: 1000)
        let reader = ProcessInspector(census: census)
        XCTAssertEqual(TabSuspension.order(reader.tree(root: 1100, tag: "pane-a")), [1101])
        add(1102, parent: 1101, name: "acme-job")
        XCTAssertEqual(TabSuspension.order(reader.tree(root: 1100, tag: "pane-a")), [1101], "another reader's lookup: a tick old")
        XCTAssertEqual(TabSuspension.order(TabSuspension.inspector(census: census).tree(root: 1100, tag: "pane-a")), [1101, 1102], "read at the press")
        XCTAssertTrue(kernel.sent.isEmpty)
    }

    func testAProcessThatIsGoneIsNotRemembered() {
        // No such pid: kill fails, and Resume has nothing to continue.
        XCTAssertEqual(TabSuspension.stop([pid_t(Int32.max - 7)]), [])
    }
}
