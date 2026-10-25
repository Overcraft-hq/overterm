import XCTest

@testable import Overterm

final class TabSuspensionTests: XCTestCase {
    private func node(_ pid: pid_t, _ parent: pid_t, _ children: [ProcessNode] = []) -> ProcessNode {
        ProcessNode(pid: pid, parent: parent, name: "p\(pid)", command: "", cpuPercent: 0, memory: 0, workingDirectory: nil, children: children)
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

    func testAProcessThatIsGoneIsNotRemembered() {
        // No such pid: kill fails, and Resume has nothing to continue.
        XCTAssertEqual(TabSuspension.stop([pid_t(Int32.max - 7)]), [])
    }
}
