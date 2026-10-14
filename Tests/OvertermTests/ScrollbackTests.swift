import XCTest

@testable import Overterm

final class ScrollbackTests: XCTestCase {
    func testTrimsBlankRowsAndKeepsTheLastLines() {
        XCTAssertEqual(Scrollback.trimmed("a\nb\n   \n\n"), "a\nb")
        let many = (1...(Scrollback.maxLines + 50)).map(String.init).joined(separator: "\n")
        let kept = Scrollback.trimmed(many).components(separatedBy: "\n")
        XCTAssertEqual(kept.count, Scrollback.maxLines)
        XCTAssertEqual(kept.first, "51")
    }

    func testNothingWorthKeepingIsNotSaved() {
        XCTAssertNil(Scrollback.save("  \n\n  "))
    }

    func testTheLauncherPrintsOnceThenBecomesTheShell() {
        let script = Scrollback.launcherScript(shell: "/bin/zsh")
        XCTAssertTrue(script.hasPrefix("#!/bin/bash\n"))
        XCTAssertTrue(script.contains(#"cat "$OVERTERM_RESTORE""#))
        XCTAssertTrue(script.contains(#"rm -f "$OVERTERM_RESTORE""#), "printed once: a later shell in the pane doesn't repeat it")
        XCTAssertTrue(script.contains(#"exec -a "-zsh" "/bin/zsh" "$@""#), "a login shell, arguments passed on")
    }

    func testOnlyShellsWhoseIntegrationSurvivesGetOne() throws {
        XCTAssertNil(Scrollback.launcher(for: "/bin/bash"))
        let zsh = try XCTUnwrap(Scrollback.launcher(for: "/bin/zsh"))
        XCTAssertEqual((zsh as NSString).lastPathComponent, "zsh", "Ghostty picks its integration by this name")
        XCTAssertFalse(zsh.contains(" "), "run through bash -c unquoted")
        XCTAssertTrue(FileManager.default.isExecutableFile(atPath: zsh))
    }

    func testTheLauncherReallyPrintsAndDeletes() throws {
        let launcher = try XCTUnwrap(Scrollback.launcher(for: "/bin/zsh"))
        let saved = FileManager.default.temporaryDirectory.appendingPathComponent("overterm-sb-\(UUID().uuidString).txt")
        try "old output line\n".write(to: saved, atomically: true, encoding: .utf8)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: launcher)
        process.arguments = ["-c", "echo shell-ran"]
        process.environment = ["OVERTERM_RESTORE": saved.path, "PATH": "/usr/bin:/bin"]
        let out = Pipe()
        process.standardOutput = out
        try process.run()
        process.waitUntilExit()
        let text = String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        XCTAssertTrue(text.hasPrefix("\u{1b}[H\u{1b}[2J\u{1b}[3Jold output line\n"), "login's greeting cleared, then the old text: \(text)")
        XCTAssertTrue(text.contains("restored from the last session"))
        XCTAssertTrue(text.hasSuffix("shell-ran\n"), "then the real shell, with the arguments")
        XCTAssertFalse(FileManager.default.fileExists(atPath: saved.path))
    }
}
