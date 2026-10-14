import XCTest

@testable import Overterm

final class SurfaceProcessesTests: XCTestCase {
    /// A git the app runs is its child too, and may start between two
    /// surfaces' logins: it must never be taken for a terminal's login.
    func testOnlyUnclaimedLoginsArePaired() {
        let children: [(pid: pid_t, start: UInt64, name: String)] = [
            (pid: 10, start: 1, name: "login"),
            (pid: 11, start: 2, name: "git"),
            (pid: 12, start: 3, name: "login"),
            (pid: 13, start: 4, name: "gh"),
            (pid: 14, start: 5, name: "login"),
        ]
        XCTAssertEqual(SurfaceProcesses.unclaimedLogins(children, claimed: [10]), [12, 14])
    }

    /// The real listing names libghostty's children as sysctl does.
    func testChildrenCarryTheirCommandNames() throws {
        let child = Process()
        child.executableURL = URL(fileURLWithPath: "/bin/sleep")
        child.arguments = ["5"]
        try child.run()
        defer { child.terminate() }
        let found = ProcessInspector.children(of: getpid()).first { $0.pid == child.processIdentifier }
        XCTAssertEqual(found?.name, "sleep")
    }
}
