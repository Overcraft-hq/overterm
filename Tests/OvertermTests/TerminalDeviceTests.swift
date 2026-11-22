import Darwin
import XCTest

@testable import Overterm
@testable import OvertermCore

/// A pane's pty as the census compares it (docs/design/activity/
/// analysis.md, 7.10): the device of the path libghostty names, what
/// `KERN_PROC_ALL` says as `e_tdev`. No surface here — the `splits`
/// scenario reads a real pane's.
final class TerminalDeviceTests: XCTestCase {
    func testACharacterDeviceUnderDevGivesItsDevice() throws {
        var info = stat()
        XCTAssertEqual(stat("/dev/null", &info), 0)
        XCTAssertEqual(TerminalView.device(ofTerminal: "/dev/null"), info.st_rdev)
    }

    func testAPtyItOpensIsTheDeviceItsChildrenWouldCarry() throws {
        var master: Int32 = -1
        var slave: Int32 = -1
        var name = [CChar](repeating: 0, count: 128)
        XCTAssertEqual(openpty(&master, &slave, &name, nil, nil), 0)
        defer {
            close(master)
            close(slave)
        }
        var info = stat()
        XCTAssertEqual(fstat(slave, &info), 0)
        let path = String(cString: name)
        XCTAssertTrue(path.hasPrefix("/dev/ttys"))
        XCTAssertEqual(TerminalView.device(ofTerminal: path), info.st_rdev)
    }

    func testAnythingElseIsNil() throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("terminal-device-\(UUID().uuidString)")
        try Data().write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }
        XCTAssertNil(TerminalView.device(ofTerminal: file.path), "a plain file")
        XCTAssertNil(TerminalView.device(ofTerminal: ""))
        XCTAssertNil(TerminalView.device(ofTerminal: "/dev"), "a folder")
        XCTAssertNil(TerminalView.device(ofTerminal: "/dev/../dev/null"), "out of /dev and back")
        XCTAssertNil(TerminalView.device(ofTerminal: "/dev/acme-no-such-tty"))
    }
}
